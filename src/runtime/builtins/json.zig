// SPDX-License-Identifier: Apache-2.0
//! Phase 4b: JSON.stringify and JSON.parse.
//! JSON.parse throws a real SyntaxError (Phase 4a path) on invalid input.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const intrinsics = @import("intrinsics.zig");

/// R1: create the JSON object with stringify/parse and bind the `JSON` global.
pub fn register(ctx: *const intrinsics.Ctx) !void {
    const arena = ctx.arena;
    const json_obj = try JsObject.create(arena, null);
    const stringify_fn = try val_mod.makeNativeFunctionNamed(arena, nativeJsonStringify, "stringify", 3);
    const parse_fn = try val_mod.makeNativeFunctionNamed(arena, nativeJsonParse, "parse", 2);
    try json_obj.set("stringify", stringify_fn);
    try json_obj.set("parse", parse_fn);
    // ES2025 json-parse-with-source: JSON.rawJSON / JSON.isRawJSON — data
    // properties with the standard { writable, !enumerable, configurable } shape.
    const data_cfg: @import("../../object/object.zig").PropAttr = .{ .writable = true, .enumerable = false, .configurable = true };
    _ = try json_obj.defineOwnData("rawJSON", try val_mod.makeNativeFunctionNamed(arena, nativeJsonRawJSON, "rawJSON", 1), data_cfg);
    _ = try json_obj.defineOwnData("isRawJSON", try val_mod.makeNativeFunctionNamed(arena, nativeJsonIsRawJSON, "isRawJSON", 1), data_cfg);
    const json_val = try val_mod.makeObject(arena, json_obj);
    try ctx.env.define("JSON", json_val);
}

/// ToString used by JSON.rawJSON: Symbol → TypeError, BigInt → decimal, objects
/// via ToPrimitive(string). Mirrors the abstract ToString operation.
fn rawJsonToString(arena: std.mem.Allocator, v_in: Value) anyerror![]const u8 {
    const coercion = @import("coercion.zig");
    var v = v_in;
    if (coercion.isObjectValue(v)) {
        v = (try coercion.toPrimitive(arena, v, .string)) orelse return "[object Object]";
    }
    if (v.bits == 0) return "undefined";
    return switch (v.unbox()) {
        .undefined_ => "undefined",
        .null_ => "null",
        .boolean => |b| if (b) "true" else "false",
        .string => |s| s,
        .number => |n| try formatNumber(arena, n),
        .bigint => |b| try b.toConst().toStringAlloc(arena, 10, .lower),
        .symbol => blk: {
            _ = try throwTypeErrorMsg(arena, "Cannot convert a Symbol value to a string");
            break :blk "";
        },
        else => "[object Object]",
    };
}

/// JSON.rawJSON(text) (ES2025): validate `text` is a single JSON primitive and
/// wrap it in a frozen null-prototype object carrying an [[IsRawJSON]] slot.
pub fn nativeJsonRawJSON(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const text = if (args.len > 0) args[0] else val_mod.makeUndefined(arena) catch unreachable;
    const json_string = try rawJsonToString(arena, text);

    // Empty, or leading/trailing JSON whitespace → SyntaxError.
    if (json_string.len == 0) return throwSyntaxError(arena, "JSON.rawJSON: empty string");
    const first = json_string[0];
    const last = json_string[json_string.len - 1];
    for ([_]u8{ ' ', '\t', '\n', '\r' }) |ws| {
        if (first == ws or last == ws) return throwSyntaxError(arena, "JSON.rawJSON: leading or trailing whitespace");
    }

    // Must parse as a single JSON value whose outermost value is not object/array.
    if (first == '{' or first == '[') return throwSyntaxError(arena, "JSON.rawJSON: value must not be an object or array");
    var parser = JsonParser{ .src = json_string, .pos = 0, .arena = arena, .track = false };
    parser.skipWs();
    _ = parser.parseValue() catch |e| return e;
    parser.skipWs();
    if (parser.pos < parser.src.len) return throwSyntaxError(arena, "JSON.parse: unexpected trailing characters");

    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, null)
    else
        try JsObject.create(arena, null);
    _ = try obj.defineOwnData("rawJSON", try val_mod.makeString(arena, json_string), .{ .writable = false, .enumerable = true, .configurable = false });
    _ = try obj.defineOwnData("[[IsRawJSON]]", try val_mod.makeBool(arena, true), .{ .writable = false, .enumerable = false, .configurable = false });
    obj.freezeSelf();
    return val_mod.makeObject(arena, obj);
}

/// JSON.isRawJSON(O) (ES2025): true iff O is an Object with an [[IsRawJSON]] slot.
pub fn nativeJsonIsRawJSON(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .object) {
        if (args[0].toPtr().object.getOwn("[[IsRawJSON]]") != null)
            return val_mod.makeBool(arena, true);
    }
    return val_mod.makeBool(arena, false);
}

fn throwTypeErrorMsg(arena: std.mem.Allocator, msg: []const u8) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.typeErrorProto())
    else
        try JsObject.create(arena, realm_mod.typeErrorProto());
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

// ---------------------------------------------------------------- stringify ---

fn jsonIsCallable(v: Value) bool {
    // Canonical IsCallable: also recognizes bound functions and callable proxies.
    return @import("../builtins/function_proto.zig").isCallableFn(v);
}

const rt = @import("../realm.zig");
const co = @import("coercion.zig");
const px = @import("proxy.zig");
const su = @import("string_proto.zig");
const fp = @import("function_proto.zig");

/// Serialization state threaded through SerializeJSON* (spec §25.5.2).
const SerState = struct {
    arena: std.mem.Allocator,
    /// A callable ReplacerFunction, or `.{}` (bits==0) when absent.
    replacer: Value,
    /// PropertyList (array-replacer allowlist), or null.
    property_list: ?[]const []const u8,
    /// Indentation unit (empty when no pretty-printing).
    gap: []const u8,
    /// Ancestor object stack for cycle detection.
    seen: *std.ArrayList(*JsObject),
};

fn isObj(v: Value) bool {
    return v.bits != 0 and v.unbox() == .object;
}

/// [[Get]](holder, key) via the active context so getters / proxy traps fire.
fn getV(arena: std.mem.Allocator, holder: Value, key: []const u8) anyerror!Value {
    if (rt.active_context) |c| return c.getProp(arena, holder, key);
    if (isObj(holder)) return holder.toPtr().object.get(key) orelse (val_mod.makeUndefined(arena) catch unreachable);
    return val_mod.makeUndefined(arena);
}

/// IsArray(v): unwraps proxy layers to their target (spec IsArray recursion).
/// §7.2.2 step 3.a makes a *revoked* proxy a TypeError rather than "not an
/// array", so this can throw.
fn isArrayValue(arena: std.mem.Allocator, v: Value) anyerror!bool {
    if (!isObj(v)) return false;
    var obj = v.toPtr().object;
    var depth: usize = 0;
    while (obj.internal_kind == .proxy and depth < 64) : (depth += 1) {
        const t = px.proxyTarget(obj) orelse return px.throwRevoked(arena);
        if (!isObj(t)) return false;
        obj = t.toPtr().object;
    }
    return obj.is_array;
}

/// SerializeJSONProperty step 4 wrapper unboxing: Number/String wrappers coerce
/// via ToNumber/ToString (honouring a user valueOf/toString — so we bypass the
/// [[PrimitiveValue]] fast path in ToPrimitive); Boolean/BigInt read the slot.
fn unwrapWrapper(arena: std.mem.Allocator, v: Value) anyerror!Value {
    const obj = v.toPtr().object;
    const prim = obj.get("[[PrimitiveValue]]") orelse return v;
    if (prim.bits == 0) return v;
    switch (prim.unbox()) {
        .number => {
            const p = (try co.ordinaryToPrimitive(arena, v, false)) orelse prim;
            return val_mod.makeNumber(arena, try rt.toNumberValue(arena, p));
        },
        .string => {
            const p = (try co.ordinaryToPrimitive(arena, v, true)) orelse prim;
            return val_mod.makeString(arena, try rt.stringPrimitive(arena, p));
        },
        .boolean, .bigint => return prim,
        else => return v,
    }
}

fn appendUEsc(arena: std.mem.Allocator, buf: *std.ArrayList(u8), unit: u16) anyerror!void {
    const hex = "0123456789abcdef";
    try buf.appendSlice(arena, "\\u");
    try buf.append(arena, hex[(unit >> 12) & 0xF]);
    try buf.append(arena, hex[(unit >> 8) & 0xF]);
    try buf.append(arena, hex[(unit >> 4) & 0xF]);
    try buf.append(arena, hex[unit & 0xF]);
}

/// QuoteJSONString (spec §25.5.2.3) over WTF-8 storage: escapes control chars,
/// emits lone surrogates as `\uXXXX`, and combines a stored high+low surrogate
/// pair back into the astral character it represents.
fn appendQuoted(arena: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) anyerror!void {
    var i: usize = 0;
    while (i < s.len) {
        const dec = su.decodeWtf8At(s, i);
        const cp = dec.cp;
        if (cp >= 0xD800 and cp <= 0xDBFF) {
            const next_i = i + dec.len;
            if (next_i < s.len) {
                const dec2 = su.decodeWtf8At(s, next_i);
                if (dec2.cp >= 0xDC00 and dec2.cp <= 0xDFFF) {
                    const astral: u21 = 0x10000 + ((@as(u21, @intCast(cp - 0xD800)) << 10) | @as(u21, @intCast(dec2.cp - 0xDC00)));
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(astral, &enc) catch 0;
                    try buf.appendSlice(arena, enc[0..n]);
                    i = next_i + dec2.len;
                    continue;
                }
            }
            try appendUEsc(arena, buf, @intCast(cp));
            i += dec.len;
            continue;
        }
        if (cp >= 0xDC00 and cp <= 0xDFFF) {
            try appendUEsc(arena, buf, @intCast(cp));
            i += dec.len;
            continue;
        }
        switch (cp) {
            '"' => try buf.appendSlice(arena, "\\\""),
            '\\' => try buf.appendSlice(arena, "\\\\"),
            0x08 => try buf.appendSlice(arena, "\\b"),
            0x09 => try buf.appendSlice(arena, "\\t"),
            0x0A => try buf.appendSlice(arena, "\\n"),
            0x0C => try buf.appendSlice(arena, "\\f"),
            0x0D => try buf.appendSlice(arena, "\\r"),
            else => {
                if (cp < 0x20) {
                    try appendUEsc(arena, buf, @intCast(cp));
                } else {
                    try buf.appendSlice(arena, s[i .. i + dec.len]);
                }
            },
        }
        i += dec.len;
    }
}

/// QuoteJSONString: the escaped code unit sequence wrapped in double quotes.
fn quotedString(arena: std.mem.Allocator, s: []const u8) anyerror![]const u8 {
    var buf = std.ArrayList(u8){};
    try buf.append(arena, '"');
    try appendQuoted(arena, &buf, s);
    try buf.append(arena, '"');
    return buf.items;
}

/// EnumerableOwnPropertyNames (string keys) — honours a proxy's [[OwnPropertyKeys]]
/// and per-key [[GetOwnProperty]] enumerable filter.
fn enumOwnStringKeys(arena: std.mem.Allocator, v: Value) anyerror![]const []const u8 {
    var list = std.ArrayList([]const u8){};
    const obj = v.toPtr().object;
    if (obj.internal_kind == .proxy) {
        if (try px.proxyOwnKeys(arena, obj)) |keys| {
            for (keys) |kv| {
                if (kv.bits == 0 or kv.unbox() != .string) continue;
                const desc = (try px.proxyGetOwnPropertyDescriptor(arena, obj, kv)) orelse continue;
                if (!isObj(desc)) continue;
                const en = desc.toPtr().object.getOwn("enumerable") orelse continue;
                if (en.bits != 0 and en.unbox() == .boolean and en.unbox().boolean)
                    try list.append(arena, kv.unbox().string);
            }
        }
        return list.items;
    }
    for (obj.ownKeys()) |k| {
        if (!obj.isEnumerable(k)) continue;
        try list.append(arena, k);
    }
    return list.items;
}

/// Build the PropertyList from an array replacer: each String/Number element
/// (or String/Number wrapper) is ToString'd; duplicates are dropped.
fn buildPropertyList(arena: std.mem.Allocator, arr_val: Value) anyerror![]const []const u8 {
    var list = std.ArrayList([]const u8){};
    const len = try rt.toLengthValue(arena, try getV(arena, arr_val, "length"));
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const e = try getV(arena, arr_val, key);
        var item: ?[]const u8 = null;
        if (e.bits != 0) switch (e.unbox()) {
            .string => |s| item = s,
            .number => |n| item = try val_mod.formatNumber(arena, n),
            .object => {
                if (e.toPtr().object.get("[[PrimitiveValue]]")) |p| {
                    if (p.bits != 0 and (p.unbox() == .string or p.unbox() == .number)) {
                        // ToString(v): ToPrimitive with the "string" hint (toString
                        // before valueOf), honouring a custom toString.
                        const prim = (try co.ordinaryToPrimitive(arena, e, true)) orelse e;
                        item = try rt.stringPrimitive(arena, prim);
                    }
                }
            },
            else => {},
        };
        if (item) |nm| {
            var dup = false;
            for (list.items) |ex| {
                if (std.mem.eql(u8, ex, nm)) {
                    dup = true;
                    break;
                }
            }
            if (!dup) try list.append(arena, nm);
        }
    }
    return list.items;
}

/// SerializeJSONProperty (spec §25.5.2.2): returns the serialized text, or null
/// when the value serializes to nothing (undefined / callable / symbol).
fn serializeProperty(st: *SerState, holder: Value, key: []const u8, indent: []const u8) anyerror!?[]const u8 {
    const arena = st.arena;
    var value = try getV(arena, holder, key);
    // toJSON — looked up for an Object or a BigInt (spec §25.5.2.2 step 2).
    if (isObj(value) or (value.bits != 0 and value.unbox() == .bigint)) {
        const tj = try getV(arena, value, "toJSON");
        if (jsonIsCallable(tj)) {
            const kv = try val_mod.makeString(arena, key);
            value = try fp.invokeCallback(arena, value, tj, &.{kv});
        }
    }
    // ReplacerFunction.
    if (jsonIsCallable(st.replacer)) {
        const kv = try val_mod.makeString(arena, key);
        value = try fp.invokeCallback(arena, holder, st.replacer, &.{ kv, value });
    }
    // Wrapper unboxing.
    if (isObj(value)) value = try unwrapWrapper(arena, value);

    if (value.bits == 0) return null;
    switch (value.unbox()) {
        .undefined_ => return null,
        .null_ => return "null",
        .boolean => |b| return if (b) "true" else "false",
        .number => |n| return try formatNumber(arena, n),
        .string => |s| return try quotedString(arena, s),
        .bigint => {
            try throwStringifyTypeErrorMsg(arena, "Do not know how to serialize a BigInt");
            unreachable;
        },
        .object => |obj| {
            // ES2025 json-parse-with-source: a rawJSON object emits its raw text.
            if (obj.getOwn("[[IsRawJSON]]") != null) {
                if (obj.getOwn("rawJSON")) |raw| {
                    if (raw.bits != 0 and raw.unbox() == .string) return raw.toPtr().string;
                }
                return null;
            }
            if (jsonIsCallable(value)) return null;
            if (try isArrayValue(st.arena, value)) return try serializeArray(st, value, indent);
            return try serializeObject(st, value, indent);
        },
        .function, .bc_function, .native_function, .symbol => return null,
    }
}

/// Assemble a `{…}`/`[…]` container from its already-serialized members, applying
/// the current gap-based indentation.
fn joinContainer(arena: std.mem.Allocator, open: u8, close: u8, members: []const []const u8, indent: []const u8, indent2: []const u8, pretty: bool) anyerror![]const u8 {
    if (members.len == 0) return arena.dupe(u8, &[_]u8{ open, close });
    var out = std.ArrayList(u8){};
    try out.append(arena, open);
    if (!pretty) {
        for (members, 0..) |m, i| {
            if (i > 0) try out.append(arena, ',');
            try out.appendSlice(arena, m);
        }
    } else {
        for (members, 0..) |m, i| {
            try out.appendSlice(arena, if (i == 0) "\n" else ",\n");
            try out.appendSlice(arena, indent2);
            try out.appendSlice(arena, m);
        }
        try out.append(arena, '\n');
        try out.appendSlice(arena, indent);
    }
    try out.append(arena, close);
    return out.items;
}

fn checkCycle(st: *SerState, obj: *JsObject) anyerror!void {
    for (st.seen.items) |a| {
        if (a == obj) {
            try throwStringifyTypeErrorMsg(st.arena, "Converting circular structure to JSON");
            unreachable;
        }
    }
}

/// SerializeJSONObject (spec §25.5.2.4).
fn serializeObject(st: *SerState, v: Value, indent: []const u8) anyerror![]const u8 {
    const arena = st.arena;
    const obj = v.toPtr().object;
    try checkCycle(st, obj);
    try st.seen.append(arena, obj);
    defer _ = st.seen.pop();

    const indent2 = try std.mem.concat(arena, u8, &.{ indent, st.gap });
    const keys = if (st.property_list) |pl| pl else try enumOwnStringKeys(arena, v);

    var members = std.ArrayList([]const u8){};
    for (keys) |P| {
        const strP = (try serializeProperty(st, v, P, indent2)) orelse continue;
        var m = std.ArrayList(u8){};
        try m.appendSlice(arena, try quotedString(arena, P));
        try m.append(arena, ':');
        if (st.gap.len > 0) try m.append(arena, ' ');
        try m.appendSlice(arena, strP);
        try members.append(arena, m.items);
    }
    return joinContainer(arena, '{', '}', members.items, indent, indent2, st.gap.len > 0);
}

/// SerializeJSONArray (spec §25.5.2.5).
fn serializeArray(st: *SerState, v: Value, indent: []const u8) anyerror![]const u8 {
    const arena = st.arena;
    const obj = v.toPtr().object;
    try checkCycle(st, obj);
    try st.seen.append(arena, obj);
    defer _ = st.seen.pop();

    const indent2 = try std.mem.concat(arena, u8, &.{ indent, st.gap });
    const len = try rt.toLengthValue(arena, try getV(arena, v, "length"));

    var members = std.ArrayList([]const u8){};
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        const strP = (try serializeProperty(st, v, key, indent2)) orelse "null";
        try members.append(arena, strP);
    }
    return joinContainer(arena, '[', ']', members.items, indent, indent2, st.gap.len > 0);
}

pub fn nativeJsonStringify(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const value0 = if (args.len > 0) args[0] else (val_mod.makeUndefined(arena) catch unreachable);

    // Replacer (args[1]): a callable is a function replacer; an array is a
    // property-name allowlist (each element ToString'd, in order).
    var replacer: Value = Value{};
    var property_list: ?[]const []const u8 = null;
    if (args.len > 1 and args[1].bits != 0) {
        if (jsonIsCallable(args[1])) {
            replacer = args[1];
        } else if (try isArrayValue(arena, args[1])) {
            property_list = try buildPropertyList(arena, args[1]);
        }
    }

    // Space (args[2]) → the gap string. A Number/String wrapper coerces via
    // ToNumber/ToString; a Number gives that many (≤10) spaces; a String gives
    // its first 10 code units; anything else gives no indentation.
    var gap: []const u8 = "";
    if (args.len > 2) {
        var space = args[2];
        if (isObj(space)) space = try unwrapWrapper(arena, space);
        if (space.bits != 0) switch (space.unbox()) {
            .number => {
                const n = try rt.toNumberValue(arena, space);
                const trunc = std.math.trunc(n);
                var count: usize = if (std.math.isNan(n) or trunc < 1) 0 else @intFromFloat(@min(trunc, 10));
                var g = std.ArrayList(u8){};
                while (count > 0) : (count -= 1) try g.append(arena, ' ');
                gap = g.items;
            },
            .string => |s| {
                gap = if (su.cuLen(s) <= 10) s else try su.cuSliceAlloc(arena, s, 0, 10);
            },
            else => {},
        };
    }

    // Top-level: holder is a wrapper { "": value } so a function replacer sees it.
    const wrapper = try JsObject.create(arena, rt.active_object_proto);
    try wrapper.set("", value0);
    const wrapper_v = try val_mod.makeObject(arena, wrapper);

    var seen = std.ArrayList(*JsObject){};
    var st = SerState{ .arena = arena, .replacer = replacer, .property_list = property_list, .gap = gap, .seen = &seen };
    const result = try serializeProperty(&st, wrapper_v, "", "");
    if (result) |s| return val_mod.makeString(arena, s);
    return val_mod.makeUndefined(arena);
}

fn throwStringifyTypeErrorMsg(arena: std.mem.Allocator, msg: []const u8) anyerror!void {
    const realm_mod = @import("../realm.zig");
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.typeErrorProto())
    else
        try JsObject.create(arena, realm_mod.typeErrorProto());
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n) or std.math.isInf(n)) return "null"; // JSON spec
    return val_mod.formatNumber(arena, n);
}

// ------------------------------------------------------------------ parse ---

/// JSON.parse: recursive descent. Throws SyntaxError on invalid JSON.
pub fn nativeJsonParse(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    // JSON.parse(text[, reviver]): text is coerced via ToString (§25.5.1 step 1),
    // so a Number/Boolean/null/object argument parses its string form, and a
    // Symbol throws a TypeError.
    const arg0 = if (args.len > 0) args[0] else (val_mod.makeUndefined(arena) catch unreachable);
    if (arg0.bits != 0 and arg0.unbox() == .symbol)
        return throwTypeErrorMsg(arena, "Cannot convert a Symbol value to a string");
    const src: []const u8 = try rt.stringPrimitive(arena, arg0);

    // A callable reviver enables InternalizeJSONProperty (+ source tracking for
    // the ES2025 json-parse-with-source `context.source` argument).
    const reviver: ?Value = if (args.len > 1 and jsonIsCallable(args[1])) args[1] else null;

    var parser = JsonParser{ .src = src, .pos = 0, .arena = arena, .track = reviver != null };
    parser.skipWs();
    const vn = parser.parseValueN() catch |e| return e;
    parser.skipWs();
    if (parser.pos < parser.src.len) {
        return throwSyntaxError(arena, "JSON.parse: unexpected trailing characters");
    }
    const result = vn.val;
    if (reviver) |rev| {
        // Root holder is a wrapper { "": value } so the reviver sees the root.
        const wrapper = if (@import("../realm.zig").active_heap) |heap|
            try JsObject.createOnHeap(heap, @import("../realm.zig").active_object_proto)
        else
            try JsObject.create(arena, @import("../realm.zig").active_object_proto);
        try wrapper.set("", result);
        return internalizeJSONProperty(arena, wrapper, "", rev, vn.node);
    }
    return result;
}

/// Source-tracking parse record: for a primitive JSON value, `source` holds the
/// exact input substring; container nodes carry their child records so the
/// reviver can be handed the right `context.source` per InternalizeJSONProperty.
const SrcNode = struct {
    kind: enum { primitive, array, object },
    source: []const u8 = "",
    /// Original parsed value (primitive nodes only); `context.source` is offered
    /// only while the holder still holds this exact value (SameValue).
    value: Value = .{},
    elements: []const *SrcNode = &.{},
    entries: []const Entry = &.{},

    const Entry = struct { key: []const u8, node: *SrcNode };
};

/// SameValue restricted to JSON primitives (number / string / boolean / null).
fn jsonSameValue(a: Value, b: Value) bool {
    if (a.bits == 0 or b.bits == 0) return a.bits == b.bits;
    const ta = a.unbox();
    const tb = b.unbox();
    return switch (ta) {
        .null_ => tb == .null_,
        .boolean => |x| tb == .boolean and x == tb.boolean,
        .number => |x| tb == .number and (x == tb.number or (x != x and tb.number != tb.number)),
        .string => |x| tb == .string and std.mem.eql(u8, x, tb.string),
        else => false,
    };
}

/// Value + its parse record (null when source tracking is disabled).
const VN = struct { val: Value, node: ?*SrcNode };

/// Build the reviver's `context` argument: a plain object that owns a `source`
/// property only when the corresponding JSON value was a primitive literal.
fn makeReviverContext(arena: std.mem.Allocator, node: ?*SrcNode, cur_val: Value) anyerror!Value {
    const realm_mod = @import("../realm.zig");
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.active_object_proto)
    else
        try JsObject.create(arena, realm_mod.active_object_proto);
    if (node) |n| {
        // Source is offered only if the holder still holds the parsed primitive
        // (a reviver that forward-modifies a sibling invalidates its source).
        if (n.kind == .primitive and jsonSameValue(n.value, cur_val))
            _ = try obj.defineOwnData("source", try val_mod.makeString(arena, n.source), .{ .writable = true, .enumerable = true, .configurable = true });
    }
    return val_mod.makeObject(arena, obj);
}

/// InternalizeJSONProperty (ES §25.5.1.1): recursively apply `reviver`, walking
/// the parse record in lockstep to supply `context.source`.
fn internalizeJSONProperty(arena: std.mem.Allocator, holder: *JsObject, name: []const u8, reviver: Value, node: ?*SrcNode) anyerror!Value {
    const fpm = @import("function_proto.zig");
    const realm_mod = @import("../realm.zig");
    // [[Get]] honouring accessors / proxy traps (a reviver may have installed a
    // getter on this key); fall back to a raw own-property read.
    const holder_v = try val_mod.makeObject(arena, holder);
    var val = if (realm_mod.active_context) |c|
        try c.getProp(arena, holder_v, name)
    else
        holder.get(name) orelse val_mod.makeUndefined(arena) catch unreachable;
    if (val.bits != 0 and val.unbox() == .object) {
        const val_obj = val.toPtr().object;
        if (try jsonIsArray(val_obj)) {
            // LengthOfArrayLike is a real [[Get]]("length") + ToLength, so a
            // Proxy trap / accessor / poisoned valueOf is observed here.
            const len_v = if (realm_mod.active_context) |c|
                try c.getProp(arena, val, "length")
            else
                val_mod.Value{};
            const len = try realm_mod.toLengthValue(arena, len_v);
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const prop = try std.fmt.allocPrint(arena, "{d}", .{i});
                const child: ?*SrcNode = if (node) |n|
                    (if (n.kind == .array and i < n.elements.len) n.elements[i] else null)
                else
                    null;
                const new_elem = try internalizeJSONProperty(arena, val_obj, prop, reviver, child);
                try applyRevivedElement(arena, val, prop, new_elem);
            }
        } else {
            // EnumerableOwnPropertyNames(val, key): [[OwnPropertyKeys]] then
            // [[GetOwnProperty]] per key, both observable on a Proxy. Snapshotting
            // up front also keeps a mutating reviver from changing what is visited.
            const keys = try jsonOwnEnumerableKeys(arena, val, val_obj);
            for (keys) |p| {
                var child: ?*SrcNode = null;
                if (node) |n| {
                    if (n.kind == .object) {
                        for (n.entries) |e| {
                            if (std.mem.eql(u8, e.key, p)) {
                                child = e.node;
                                break;
                            }
                        }
                    }
                }
                const new_elem = try internalizeJSONProperty(arena, val_obj, p, reviver, child);
                try applyRevivedElement(arena, val, p, new_elem);
            }
        }
    }
    const name_v = try val_mod.makeString(arena, name);
    const ctx = try makeReviverContext(arena, node, val);
    return fpm.invokeCallback(arena, holder_v, reviver, &.{ name_v, val, ctx });
}

/// IsArray (§7.2.2) for the reviver walk: recurses through Proxy targets.
fn jsonIsArray(obj_in: *JsObject) anyerror!bool {
    const proxy_mod = @import("proxy.zig");
    var o = obj_in;
    var depth: usize = 0;
    while (o.internal_kind == .proxy and depth < 64) : (depth += 1) {
        const target = proxy_mod.proxyTarget(o) orelse return proxy_mod.throwRevoked(std.heap.page_allocator);
        if (target.bits == 0 or target.unbox() != .object) return false;
        o = target.toPtr().object;
    }
    return o.is_array;
}

/// Own enumerable STRING keys of `val`, via the observable [[OwnPropertyKeys]] +
/// [[GetOwnProperty]] pair (Object.keys already implements exactly that).
fn jsonOwnEnumerableKeys(arena: std.mem.Allocator, val: Value, val_obj: *JsObject) anyerror![][]const u8 {
    const realm_mod = @import("../realm.zig");
    var out = std.ArrayList([]const u8){};
    if (val_obj.internal_kind == .proxy) {
        const obj_methods = @import("object_methods.zig");
        const arr = try obj_methods.nativeObjectKeys(arena, Value{}, &[_]Value{val});
        if (arr.bits != 0 and arr.unbox() == .object) {
            const ao = arr.toPtr().object;
            var i: u32 = 0;
            while (i < ao.getArrayLength()) : (i += 1) {
                const k = try std.fmt.allocPrint(arena, "{d}", .{i});
                const kv = ao.get(k) orelse continue;
                try out.append(arena, try realm_mod.stringPrimitive(arena, kv));
            }
        }
        return out.items;
    }
    for (val_obj.ownKeys()) |k| {
        if (val_obj.isEnumerable(k)) try out.append(arena, k);
    }
    return out.items;
}

/// InternalizeJSONProperty steps 2.b.ii/iii: an undefined result DELETES the
/// property (DeletePropertyOrThrow), anything else is installed with
/// CreateDataPropertyOrThrow. Both are throwing forms; the old code used the
/// silent `deleteOwn`/`set` pair.
fn applyRevivedElement(arena: std.mem.Allocator, val: Value, prop: []const u8, new_elem: Value) anyerror!void {
    const reflect = @import("reflect.zig");
    const realm_mod = @import("../realm.zig");
    const key_v = try val_mod.makeString(arena, prop);
    if (new_elem.bits == 0 or new_elem.unbox() == .undefined_) {
        // `Perform ? val.[[Delete]](P)` — a throw from a Proxy trap propagates,
        // but a plain `false` result is discarded (there is no OrThrow here).
        _ = try reflect.nativeReflectDeleteProperty(arena, Value{}, &[_]Value{ val, key_v });
        return;
    }
    // CreateDataProperty, NOT CreateDataPropertyOrThrow: a non-configurable
    // existing property makes the create fail SILENTLY and the old value stays.
    const desc = try JsObject.create(arena, realm_mod.active_object_proto);
    try desc.set("value", new_elem);
    try desc.set("writable", try val_mod.makeBool(arena, true));
    try desc.set("enumerable", try val_mod.makeBool(arena, true));
    try desc.set("configurable", try val_mod.makeBool(arena, true));
    _ = try reflect.nativeReflectDefineProperty(arena, Value{}, &[_]Value{ val, key_v, try val_mod.makeObject(arena, desc) });
}

/// Error-only variant of throwSyntaxError, usable in any `!T` return context.
fn jsonSynErr(arena: std.mem.Allocator, msg: []const u8) anyerror {
    _ = throwSyntaxError(arena, msg) catch {};
    return error.JsException;
}

fn throwSyntaxError(arena: std.mem.Allocator, msg: []const u8) anyerror!Value {
    // Build a SyntaxError object via the Phase 4a prototype.
    const realm_mod = @import("../realm.zig");
    const proto: ?*JsObject = realm_mod.syntaxErrorProto();
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, proto)
    else
        try JsObject.create(arena, proto);
    const msg_val = try val_mod.makeString(arena, msg);
    const name_val = try val_mod.makeString(arena, "SyntaxError");
    try obj.set("message", msg_val);
    try obj.set("name", name_val);
    const err_val = try val_mod.makeObject(arena, obj);
    // Store in thread-local so the VM can retrieve it.
    realm_mod.pending_exception = err_val;
    return error.JsException;
}

const JsonParser = struct {
    src: []const u8,
    pos: usize,
    arena: std.mem.Allocator,
    track: bool = false,

    /// Allocate a primitive parse record spanning src[start..self.pos].
    fn mkPrim(self: *JsonParser, start: usize, value: Value) anyerror!?*SrcNode {
        if (!self.track) return null;
        const n = try self.arena.create(SrcNode);
        n.* = .{ .kind = .primitive, .source = self.src[start..self.pos], .value = value };
        return n;
    }

    /// Source-tracking parse: returns the value paired with its parse record.
    fn parseValueN(self: *JsonParser) anyerror!VN {
        self.skipWs();
        const start = self.pos;
        const c = self.peek() orelse return jsonSynErr(self.arena, "JSON.parse: unexpected end of input");
        switch (c) {
            '{' => return self.parseObjectN(),
            '[' => return self.parseArrayN(),
            '"' => {
                const v = try self.parseString();
                return .{ .val = v, .node = try self.mkPrim(start, v) };
            },
            't', 'f', 'n', '-', '0'...'9' => {
                const v = try self.parseValue();
                return .{ .val = v, .node = try self.mkPrim(start, v) };
            },
            else => return jsonSynErr(self.arena, "JSON.parse: unexpected character"),
        }
    }

    fn parseObjectN(self: *JsonParser) anyerror!VN {
        const realm_mod = @import("../realm.zig");
        try self.expectChar('{');
        const obj = if (realm_mod.active_heap) |heap|
            try JsObject.createOnHeap(heap, realm_mod.active_object_proto)
        else
            try JsObject.create(self.arena, realm_mod.active_object_proto);
        var entries = std.ArrayList(SrcNode.Entry){};
        self.skipWs();
        if (self.peek() == '}') {
            self.pos += 1;
            return self.finishObj(obj, &entries);
        }
        while (true) {
            self.skipWs();
            if (self.peek() != '"') return jsonSynErr(self.arena, "JSON.parse: expected string key");
            const key_val = try self.parseString();
            const key_str = key_val.toPtr().string;
            self.skipWs();
            try self.expectChar(':');
            const child = try self.parseValueN();
            try obj.set(key_str, child.val);
            if (self.track) {
                if (child.node) |cn| try entries.append(self.arena, .{ .key = key_str, .node = cn });
            }
            self.skipWs();
            const next = self.peek() orelse return jsonSynErr(self.arena, "JSON.parse: unexpected end of object");
            if (next == '}') {
                self.pos += 1;
                break;
            }
            if (next != ',') return jsonSynErr(self.arena, "JSON.parse: expected ',' or '}'");
            self.pos += 1;
        }
        return self.finishObj(obj, &entries);
    }

    fn finishObj(self: *JsonParser, obj: *JsObject, entries: *std.ArrayList(SrcNode.Entry)) anyerror!VN {
        const v = try val_mod.makeObject(self.arena, obj);
        if (!self.track) return .{ .val = v, .node = null };
        const n = try self.arena.create(SrcNode);
        n.* = .{ .kind = .object, .entries = entries.items };
        return .{ .val = v, .node = n };
    }

    fn parseArrayN(self: *JsonParser) anyerror!VN {
        const realm_mod = @import("../realm.zig");
        try self.expectChar('[');
        const arr = if (realm_mod.active_heap) |heap|
            try JsObject.createArrayOnHeap(heap, realm_mod.active_array_proto)
        else
            try JsObject.createArray(self.arena, realm_mod.active_array_proto);
        var elements = std.ArrayList(*SrcNode){};
        self.skipWs();
        if (self.peek() == ']') {
            self.pos += 1;
            return self.finishArr(arr, 0, &elements);
        }
        var idx: u32 = 0;
        while (true) {
            const child = try self.parseValueN();
            const key = try std.fmt.allocPrint(self.arena, "{d}", .{idx});
            try arr.set(key, child.val);
            if (self.track) {
                if (child.node) |cn| try elements.append(self.arena, cn);
            }
            idx += 1;
            self.skipWs();
            const next = self.peek() orelse return jsonSynErr(self.arena, "JSON.parse: unexpected end of array");
            if (next == ']') {
                self.pos += 1;
                break;
            }
            if (next != ',') return jsonSynErr(self.arena, "JSON.parse: expected ',' or ']'");
            self.pos += 1;
        }
        return self.finishArr(arr, idx, &elements);
    }

    fn finishArr(self: *JsonParser, arr: *JsObject, len: u32, elements: *std.ArrayList(*SrcNode)) anyerror!VN {
        arr.array_length = len;
        const v = try val_mod.makeObject(self.arena, arr);
        if (!self.track) return .{ .val = v, .node = null };
        const n = try self.arena.create(SrcNode);
        n.* = .{ .kind = .array, .elements = elements.items };
        return .{ .val = v, .node = n };
    }

    fn peek(self: *JsonParser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn consume(self: *JsonParser) ?u8 {
        if (self.pos >= self.src.len) return null;
        const c = self.src[self.pos];
        self.pos += 1;
        return c;
    }

    fn skipWs(self: *JsonParser) void {
        while (self.pos < self.src.len) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    fn expectChar(self: *JsonParser, c: u8) anyerror!void {
        const got = self.consume() orelse {
            _ = try throwSyntaxError(self.arena, "JSON.parse: unexpected end of input");
            unreachable;
        };
        if (got != c) {
            _ = try throwSyntaxError(self.arena, "JSON.parse: unexpected character");
            unreachable;
        }
    }

    fn parseValue(self: *JsonParser) anyerror!Value {
        self.skipWs();
        const c = self.peek() orelse return throwSyntaxError(self.arena, "JSON.parse: unexpected end of input");
        return switch (c) {
            '"' => self.parseString(),
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            't' => self.parseLiteral("true", try val_mod.makeBool(self.arena, true)),
            'f' => self.parseLiteral("false", try val_mod.makeBool(self.arena, false)),
            'n' => self.parseLiteral("null", try val_mod.makeNull(self.arena)),
            '-', '0'...'9' => self.parseNumber(),
            else => throwSyntaxError(self.arena, "JSON.parse: unexpected character"),
        };
    }

    fn parseLiteral(self: *JsonParser, lit: []const u8, result: Value) anyerror!Value {
        if (self.pos + lit.len > self.src.len) return throwSyntaxError(self.arena, "JSON.parse: unexpected end of input");
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + lit.len], lit)) {
            return throwSyntaxError(self.arena, "JSON.parse: invalid literal");
        }
        self.pos += lit.len;
        return result;
    }

    fn parseString(self: *JsonParser) anyerror!Value {
        try self.expectChar('"');
        var buf = std.ArrayList(u8){};
        while (true) {
            const c = self.consume() orelse return throwSyntaxError(self.arena, "JSON.parse: unterminated string");
            if (c == '"') break;
            // The JSON string grammar forbids unescaped control characters
            // U+0000..U+001F (§25.5.1 JSONString production).
            if (c < 0x20) return throwSyntaxError(self.arena, "JSON.parse: unescaped control character in string");
            if (c == '\\') {
                const esc = self.consume() orelse return throwSyntaxError(self.arena, "JSON.parse: unterminated escape");
                switch (esc) {
                    '"' => try buf.append(self.arena, '"'),
                    '\\' => try buf.append(self.arena, '\\'),
                    '/' => try buf.append(self.arena, '/'),
                    'n' => try buf.append(self.arena, '\n'),
                    'r' => try buf.append(self.arena, '\r'),
                    't' => try buf.append(self.arena, '\t'),
                    'b' => try buf.append(self.arena, 0x08),
                    'f' => try buf.append(self.arena, 0x0C),
                    'u' => {
                        if (self.pos + 4 > self.src.len) return throwSyntaxError(self.arena, "JSON.parse: invalid unicode escape");
                        const hex = self.src[self.pos .. self.pos + 4];
                        self.pos += 4;
                        const code = std.fmt.parseInt(u16, hex, 16) catch
                            return throwSyntaxError(self.arena, "JSON.parse: invalid unicode escape");
                        var seq: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(code, &seq) catch
                            return throwSyntaxError(self.arena, "JSON.parse: invalid codepoint");
                        try buf.appendSlice(self.arena, seq[0..n]);
                    },
                    else => return throwSyntaxError(self.arena, "JSON.parse: invalid escape sequence"),
                }
            } else {
                try buf.append(self.arena, c);
            }
        }
        return val_mod.makeString(self.arena, buf.items);
    }

    fn parseNumber(self: *JsonParser) anyerror!Value {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        if (self.peek() == '0') {
            self.pos += 1;
        } else if (self.peek()) |d| {
            if (d >= '1' and d <= '9') {
                while (self.peek()) |dd| {
                    if (dd >= '0' and dd <= '9') self.pos += 1 else break;
                }
            } else {
                return throwSyntaxError(self.arena, "JSON.parse: invalid number");
            }
        }
        if (self.peek() == '.') {
            self.pos += 1;
            while (self.peek()) |dd| {
                if (dd >= '0' and dd <= '9') self.pos += 1 else break;
            }
        }
        if (self.peek()) |e| {
            if (e == 'e' or e == 'E') {
                self.pos += 1;
                if (self.peek()) |pm| {
                    if (pm == '+' or pm == '-') self.pos += 1;
                }
                while (self.peek()) |dd| {
                    if (dd >= '0' and dd <= '9') self.pos += 1 else break;
                }
            }
        }
        const num_str = self.src[start..self.pos];
        const n = std.fmt.parseFloat(f64, num_str) catch
            return throwSyntaxError(self.arena, "JSON.parse: invalid number");
        return val_mod.makeNumber(self.arena, n);
    }

    fn parseObject(self: *JsonParser) anyerror!Value {
        try self.expectChar('{');
        const realm_mod = @import("../realm.zig");
        const obj = if (realm_mod.active_heap) |heap|
            try JsObject.createOnHeap(heap, realm_mod.active_object_proto)
        else
            try JsObject.create(self.arena, realm_mod.active_object_proto);

        self.skipWs();
        if (self.peek() == '}') {
            self.pos += 1;
            return val_mod.makeObject(self.arena, obj);
        }

        while (true) {
            self.skipWs();
            if (self.peek() != '"') return throwSyntaxError(self.arena, "JSON.parse: expected string key");
            const key_val = try self.parseString();
            const key_str = if (key_val.bits != 0 and key_val.unbox() == .string)
                key_val.toPtr().string
            else
                return throwSyntaxError(self.arena, "JSON.parse: expected string key");

            self.skipWs();
            try self.expectChar(':');
            self.skipWs();
            const val_ = try self.parseValue();
            try obj.set(key_str, val_);
            self.skipWs();
            const next = self.peek() orelse return throwSyntaxError(self.arena, "JSON.parse: unexpected end of object");
            if (next == '}') {
                self.pos += 1;
                break;
            }
            if (next != ',') return throwSyntaxError(self.arena, "JSON.parse: expected ',' or '}'");
            self.pos += 1;
        }
        return val_mod.makeObject(self.arena, obj);
    }

    fn parseArray(self: *JsonParser) anyerror!Value {
        try self.expectChar('[');
        const realm_mod = @import("../realm.zig");
        const arr = if (realm_mod.active_heap) |heap|
            try JsObject.createArrayOnHeap(heap, realm_mod.active_array_proto)
        else
            try JsObject.createArray(self.arena, realm_mod.active_array_proto);

        self.skipWs();
        if (self.peek() == ']') {
            self.pos += 1;
            return val_mod.makeObject(self.arena, arr);
        }

        var idx: u32 = 0;
        while (true) {
            self.skipWs();
            const elem = try self.parseValue();
            const key = try std.fmt.allocPrint(self.arena, "{d}", .{idx});
            try arr.set(key, elem);
            idx += 1;
            self.skipWs();
            const next = self.peek() orelse return throwSyntaxError(self.arena, "JSON.parse: unexpected end of array");
            if (next == ']') {
                self.pos += 1;
                break;
            }
            if (next != ',') return throwSyntaxError(self.arena, "JSON.parse: expected ',' or ']'");
            self.pos += 1;
        }
        arr.array_length = idx;
        return val_mod.makeObject(self.arena, arr);
    }
};
