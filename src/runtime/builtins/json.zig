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
        try JsObject.createOnHeap(heap, realm_mod.error_proto_TypeError)
    else
        try JsObject.create(arena, realm_mod.error_proto_TypeError);
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

/// SerializeJSONProperty transform (ES §25.5.2.2 partial): call value.toJSON(key)
/// if present, then apply a function `replacer` as replacer(holder, key, value).
fn applyProp(arena: std.mem.Allocator, replacer: Value, holder: *JsObject, key: []const u8, value_in: Value) anyerror!Value {
    const fpm = @import("function_proto.zig");
    var value = value_in;
    if (value.bits != 0 and value.unbox() == .object) {
        if (value.toPtr().object.get("toJSON")) |tj| {
            if (jsonIsCallable(tj)) {
                const kv = try val_mod.makeString(arena, key);
                value = try fpm.invokeCallback(arena, value, tj, &.{kv});
            }
        }
    }
    if (jsonIsCallable(replacer)) {
        const kv = try val_mod.makeString(arena, key);
        const holder_v = try val_mod.makeObject(arena, holder);
        value = try fpm.invokeCallback(arena, holder_v, replacer, &.{ kv, value });
    }
    return value;
}

pub fn nativeJsonStringify(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0 or args[0].bits == 0) {
        return val_mod.makeUndefined(arena);
    }

    // Replacer (args[1]): a callable is a function replacer; an array is a
    // property-name allowlist (each element ToString'd, in order).
    var replacer: Value = Value{};
    var key_filter: ?[]const []const u8 = null;
    if (args.len > 1 and args[1].bits != 0) {
        if (jsonIsCallable(args[1])) {
            replacer = args[1];
        } else if (args[1].unbox() == .object and args[1].toPtr().object.is_array) {
            const arr = args[1].toPtr().object;
            var list = std.ArrayList([]const u8){};
            var i: usize = 0;
            while (i < arr.array_length) : (i += 1) {
                const k = try std.fmt.allocPrint(arena, "{d}", .{i});
                const e = arr.getOwn(k) orelse continue;
                if (e.bits == 0) continue;
                const name: ?[]const u8 = switch (e.unbox()) {
                    .string => |s| s,
                    .number => |n| try formatNumber(arena, n),
                    else => null,
                };
                if (name) |nm| {
                    // Dedup: JSON.stringify allowlist ignores repeat entries.
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
            key_filter = list.items;
        }
    }

    const indent: usize = if (args.len > 2 and args[2].bits != 0)
        switch (args[2].unbox()) {
            .number => |n| blk: {
                if (n < 0.0) break :blk 0;
                const u: usize = @intCast(val_mod.f64ToI64Sat(n));
                break :blk if (u > 10) 10 else u;
            },
            else => 0,
        }
    else
        0;

    // Top-level: holder is a wrapper { "": value } so a function replacer sees it.
    const wrapper = try JsObject.create(arena, null);
    try wrapper.set("", args[0]);
    const top = try applyProp(arena, replacer, wrapper, "", args[0]);

    var buf = std.ArrayList(u8){};
    // Ancestor stack for circular-reference detection (throws TypeError on a cycle).
    var seen = std.ArrayList(*JsObject){};
    try stringifyValue(arena, &buf, top, indent, 0, &seen, replacer, key_filter);
    // If result is empty (e.g. function top-level), return undefined
    if (buf.items.len == 0) return val_mod.makeUndefined(arena);
    return val_mod.makeString(arena, buf.items);
}

fn stringifyValue(
    arena: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    v: Value,
    indent: usize,
    depth: usize,
    seen: *std.ArrayList(*JsObject),
    replacer: Value,
    key_filter: ?[]const []const u8,
) anyerror!void {
    if (v.bits == 0) {
        try buf.appendSlice(arena, "undefined");
        return;
    }
    switch (v.unbox()) {
        .undefined_ => {
            try buf.appendSlice(arena, "undefined");
        },
        .null_ => try buf.appendSlice(arena, "null"),
        .boolean => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .number => |n| {
            const s = try formatNumber(arena, n);
            try buf.appendSlice(arena, s);
        },
        .string => |s| {
            try buf.append(arena, '"');
            try appendJsonString(arena, buf, s);
            try buf.append(arena, '"');
        },
        .object => |obj| {
            // ES2025 json-parse-with-source: a rawJSON object serializes as its
            // stored raw text, emitted verbatim (already valid JSON).
            if (obj.getOwn("[[IsRawJSON]]") != null) {
                if (obj.getOwn("rawJSON")) |raw| {
                    if (raw.bits != 0 and raw.unbox() == .string)
                        try buf.appendSlice(arena, raw.toPtr().string);
                }
                return;
            }
            // §25.5.2.2 step 4: Number / String / Boolean / BigInt wrapper objects
            // serialize as their underlying primitive (a BigInt wrapper throws).
            if (obj.getOwn("[[PrimitiveValue]]")) |prim| {
                if (prim.bits != 0) switch (prim.unbox()) {
                    .number, .string, .boolean => return stringifyValue(arena, buf, prim, indent, depth, seen, replacer, key_filter),
                    .bigint => return throwStringifyTypeErrorMsg(arena, "Do not know how to serialize a BigInt"),
                    else => {},
                };
            }
            // Circular-structure guard: a value currently being stringified that
            // re-references an ancestor → TypeError (per spec SerializeJSONProperty).
            for (seen.items) |a| {
                if (a == obj) return throwStringifyTypeError(arena);
            }
            // A callable object (function) produces nothing (caller emits null in arrays).
            if (obj.get("__call__") != null) return;
            try seen.append(arena, obj);
            defer _ = seen.pop();
            if (obj.is_array) {
                try stringifyArray(arena, buf, obj, indent, depth, seen, replacer, key_filter);
            } else {
                try stringifyObject(arena, buf, obj, indent, depth, seen, replacer, key_filter);
            }
        },
        // A BigInt value cannot be serialized (§25.5.2.2 step 10) → TypeError.
        .bigint => return throwStringifyTypeErrorMsg(arena, "Do not know how to serialize a BigInt"),
        // functions, native_function, symbol: produce nothing (caller uses "null" for arrays)
        .function, .bc_function, .native_function, .symbol => {},
    }
}

fn throwStringifyTypeError(arena: std.mem.Allocator) anyerror!void {
    return throwStringifyTypeErrorMsg(arena, "Converting circular structure to JSON");
}

fn throwStringifyTypeErrorMsg(arena: std.mem.Allocator, msg: []const u8) anyerror!void {
    const realm_mod = @import("../realm.zig");
    const obj = if (realm_mod.active_heap) |heap|
        try JsObject.createOnHeap(heap, realm_mod.error_proto_TypeError)
    else
        try JsObject.create(arena, realm_mod.error_proto_TypeError);
    try obj.set("message", try val_mod.makeString(arena, msg));
    try obj.set("name", try val_mod.makeString(arena, "TypeError"));
    realm_mod.pending_exception = try val_mod.makeObject(arena, obj);
    return error.JsException;
}

fn stringifyObject(
    arena: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    obj: *JsObject,
    indent: usize,
    depth: usize,
    seen: *std.ArrayList(*JsObject),
    replacer: Value,
    key_filter: ?[]const []const u8,
) anyerror!void {
    try buf.append(arena, '{');
    var first = true;
    // With an array replacer, iterate the allowlist order; otherwise own enumerable keys.
    const keys: []const []const u8 = if (key_filter) |kf| kf else obj.ownKeys();
    for (keys) |k| {
        if (key_filter == null and !obj.isEnumerable(k)) continue;
        const raw = obj.getOwn(k) orelse continue;
        // SerializeJSONProperty: toJSON then function replacer.
        const val = try applyProp(arena, replacer, obj, k, raw);
        // Skip functions and undefined values (per JSON spec), post-transform.
        if (val.bits != 0) {
            const tag = val.unbox();
            if (tag == .function or tag == .bc_function or tag == .native_function or tag == .undefined_ or tag == .symbol) continue;
            if (tag == .object and val.toPtr().object.get("__call__") != null) continue;
        } else {
            continue; // zero = undefined
        }

        if (!first) try buf.append(arena, ',');
        first = false;

        if (indent > 0) {
            try buf.append(arena, '\n');
            try appendIndent(arena, buf, indent, depth + 1);
        }
        try buf.append(arena, '"');
        try appendJsonString(arena, buf, k);
        try buf.append(arena, '"');
        try buf.append(arena, ':');
        if (indent > 0) try buf.append(arena, ' ');

        try stringifyValue(arena, buf, val, indent, depth + 1, seen, replacer, key_filter);
    }
    if (indent > 0 and !first) {
        try buf.append(arena, '\n');
        try appendIndent(arena, buf, indent, depth);
    }
    try buf.append(arena, '}');
}

fn stringifyArray(
    arena: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    arr: *JsObject,
    indent: usize,
    depth: usize,
    seen: *std.ArrayList(*JsObject),
    replacer: Value,
    key_filter: ?[]const []const u8,
) anyerror!void {
    try buf.append(arena, '[');
    const len = arr.array_length;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (i > 0) try buf.append(arena, ',');
        if (indent > 0) {
            try buf.append(arena, '\n');
            try appendIndent(arena, buf, indent, depth + 1);
        }
        const key = try std.fmt.allocPrint(arena, "{d}", .{i});
        // An array replacer (key_filter) does NOT filter array indices; apply
        // toJSON + function replacer per element (holder=arr, key=index string).
        const raw = arr.getOwn(key) orelse Value{};
        const elem = try applyProp(arena, replacer, arr, key, raw);
        // Functions/undefined/symbol in arrays become "null"
        if (elem.bits != 0) {
            const tag = elem.unbox();
            if (tag == .function or tag == .bc_function or tag == .native_function or tag == .undefined_ or tag == .symbol or
                (tag == .object and elem.toPtr().object.get("__call__") != null))
            {
                try buf.appendSlice(arena, "null");
                continue;
            }
        } else {
            try buf.appendSlice(arena, "null");
            continue;
        }
        try stringifyValue(arena, buf, elem, indent, depth + 1, seen, replacer, key_filter);
    }
    if (indent > 0 and len > 0) {
        try buf.append(arena, '\n');
        try appendIndent(arena, buf, indent, depth);
    }
    try buf.append(arena, ']');
}

fn appendIndent(arena: std.mem.Allocator, buf: *std.ArrayList(u8), spaces: usize, depth: usize) anyerror!void {
    const total = spaces * depth;
    var i: usize = 0;
    while (i < total) : (i += 1) try buf.append(arena, ' ');
}

fn appendJsonString(arena: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) anyerror!void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(arena, "\\\""),
            '\\' => try buf.appendSlice(arena, "\\\\"),
            '\n' => try buf.appendSlice(arena, "\\n"),
            '\r' => try buf.appendSlice(arena, "\\r"),
            '\t' => try buf.appendSlice(arena, "\\t"),
            0x08 => try buf.appendSlice(arena, "\\b"),
            0x0C => try buf.appendSlice(arena, "\\f"),
            else => try buf.append(arena, c),
        }
    }
}

fn formatNumber(arena: std.mem.Allocator, n: f64) ![]const u8 {
    if (std.math.isNan(n) or std.math.isInf(n)) return "null"; // JSON spec
    return val_mod.formatNumber(arena, n);
}

// ------------------------------------------------------------------ parse ---

/// JSON.parse: recursive descent. Throws SyntaxError on invalid JSON.
pub fn nativeJsonParse(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len == 0) {
        return throwSyntaxError(arena, "JSON.parse: missing argument");
    }
    const src: []const u8 = if (args[0].bits != 0 and args[0].unbox() == .string)
        args[0].toPtr().string
    else
        return throwSyntaxError(arena, "JSON.parse: argument is not a string");

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
        if (val_obj.is_array) {
            const len = val_obj.array_length;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const prop = try std.fmt.allocPrint(arena, "{d}", .{i});
                const child: ?*SrcNode = if (node) |n|
                    (if (n.kind == .array and i < n.elements.len) n.elements[i] else null)
                else
                    null;
                const new_elem = try internalizeJSONProperty(arena, val_obj, prop, reviver, child);
                if (new_elem.bits == 0 or new_elem.unbox() == .undefined_) {
                    _ = try val_obj.deleteOwn(prop);
                } else {
                    try val_obj.set(prop, new_elem);
                }
            }
        } else {
            // Snapshot enumerable own keys before iterating (reviver may mutate).
            var keys = std.ArrayList([]const u8){};
            for (val_obj.ownKeys()) |k| {
                if (val_obj.isEnumerable(k)) try keys.append(arena, k);
            }
            for (keys.items) |p| {
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
                if (new_elem.bits == 0 or new_elem.unbox() == .undefined_) {
                    _ = try val_obj.deleteOwn(p);
                } else {
                    try val_obj.set(p, new_elem);
                }
            }
        }
    }
    const name_v = try val_mod.makeString(arena, name);
    const ctx = try makeReviverContext(arena, node, val);
    return fpm.invokeCallback(arena, holder_v, reviver, &.{ name_v, val, ctx });
}

/// Error-only variant of throwSyntaxError, usable in any `!T` return context.
fn jsonSynErr(arena: std.mem.Allocator, msg: []const u8) anyerror {
    _ = throwSyntaxError(arena, msg) catch {};
    return error.JsException;
}

fn throwSyntaxError(arena: std.mem.Allocator, msg: []const u8) anyerror!Value {
    // Build a SyntaxError object via the Phase 4a prototype.
    const realm_mod = @import("../realm.zig");
    const proto: ?*JsObject = realm_mod.error_proto_SyntaxError;
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
