// SPDX-License-Identifier: Apache-2.0
//! Milestone 16 (ESM) — Phase 2: the Module Namespace Exotic Object (ES §10.4.6).
//!
//! `import * as ns from 'm'` binds `ns` to a namespace exotic object. It is a
//! thin exotic wrapper over the imported module's live exports object (the CJS
//! `exports` produced by the import/export desugar), stored in `internal_slot`:
//!
//!   * `[[Prototype]]` is null and the object is non-extensible.
//!   * `[[Get]]`(string) reads the *current* value of the named export (live),
//!     throwing ReferenceError for uninitialized bindings (TDZ). Symbol keys
//!     are ordinary (`Symbol.toStringTag` is an own data property valued
//!     "Module").
//!   * `[[Set]]`/`[[Delete]]`/`[[DefineOwnProperty]]`/`[[SetPrototypeOf]]` reject
//!     (return false → a TypeError under the strict module goal).
//!   * `[[GetOwnProperty]]` reports `{ value, writable: true, enumerable: true,
//!     configurable: false }` for an export, and `[[OwnPropertyKeys]]` lists the
//!     export names sorted by code unit followed by the symbol keys.
//!
//! The exotic behaviour lives at the VM property-op dispatch points and the
//! `Object.*`/`Reflect.*` natives, each guarded by `internal_kind ==
//! .module_namespace`, so non-module objects are wholly unaffected.
const std = @import("std");
const object = @import("../../object/object.zig");
const JsObject = object.JsObject;
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;

/// True if `v` is a Module Namespace exotic object.
pub fn isNamespace(v: Value) bool {
    return v.bits != 0 and v.unbox() == .object and v.toPtr().object.internal_kind == .module_namespace;
}

/// The backing live exports object, or null if `o` is not a namespace.
pub fn backing(o: *JsObject) ?*JsObject {
    if (o.internal_kind != .module_namespace) return null;
    if (o.internal_slot) |p| return @ptrCast(@alignCast(p));
    return null;
}

/// Read the export-names array (stored on the backing exports object under a
/// private symbol during module init). Returns null if the list is not present
/// (legacy or non-module path).
fn exportNamesArr(backing_obj: *JsObject) ?*JsObject {
    const realm_mod = @import("../realm.zig");
    if (realm_mod.active_sym_export_names) |sym| {
        if (backing_obj.getOwnSym(sym)) |arr_val| {
            if (arr_val.bits != 0 and arr_val.unbox() == .object) {
                return arr_val.toPtr().object;
            }
        }
    }
    return null;
}

/// Read the TDZ-only export-names array (stored on the backing exports object
/// under a separate private symbol during module init). Returns null if no
/// TDZ-specific list was registered (all exports are TDZ).
fn tdzNamesArr(backing_obj: *JsObject) ?*JsObject {
    const realm_mod = @import("../realm.zig");
    if (realm_mod.active_sym_tdz_export_names) |sym| {
        if (backing_obj.getOwnSym(sym)) |arr_val| {
            if (arr_val.bits != 0 and arr_val.unbox() == .object) {
                return arr_val.toPtr().object;
            }
        }
    }
    return null;
}

/// Is `key` an exported name (appears in the module's export-names list)?
/// Unlike the old `hasExport`, this checks the private export-names list on
/// the backing object, NOT merely the backing's own properties, so it returns
/// true even for uninitialized (TDZ) exports that haven't been written yet.
pub fn hasExport(o: *JsObject, key: []const u8) bool {
    const b = backing(o) orelse return false;
    const arr = exportNamesArr(b) orelse return b.hasOwn(key);
    const n = arr.getArrayLength();
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i < n) : (i += 1) {
        const idx_key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return false;
        if (arr.get(idx_key)) |name_val| {
            if (name_val.bits != 0 and name_val.unbox() == .string) {
                if (std.mem.eql(u8, name_val.toPtr().string, key)) return true;
            }
        }
    }
    return false;
}

/// True when `key` is a known export name whose backing property is still
/// uninitialized (TDZ → [[Get]] must throw ReferenceError). Returns false for
/// non-exports and for initialized exports.
pub fn isTDZ(o: *JsObject, key: []const u8) bool {
    if (o.internal_kind != .module_namespace) return false;
    const b = backing(o) orelse return false;
    // Read the backing's value for this key. If it's the TDZ marker symbol
    // (pre-populated by __initExports__ before the module body runs), the
    // binding is uninitialized => ReferenceError.
    const realm_mod = @import("../realm.zig");
    const marker = realm_mod.tdz_marker orelse return false;
    if (b.getOwn(key)) |v| {
        if (v.bits != 0 and v.unbox() == .symbol and
            v.toPtr().symbol == marker.toPtr().symbol)
        {
            return true; // TDZ marker
        }
        return false; // initialized (any non-marker value)
    }
    // No own property: check the TDZ-only export list (let/const/class bindings
    // are uninitialized during instantiation). var/function bindings are NOT
    // TDZ — they are initialized to undefined / function value and so are not
    // in the TDZ list.
    const tdz_arr = tdzNamesArr(b) orelse {
        // No TDZ-specific list: fall back to the full export-names list (legacy).
        const arr = exportNamesArr(b) orelse return false;
        const n = arr.getArrayLength();
        var i: u32 = 0;
        var buf: [32]u8 = undefined;
        while (i < n) : (i += 1) {
            const idx_key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return false;
            if (arr.get(idx_key)) |name_val| {
                if (name_val.bits != 0 and name_val.unbox() == .string) {
                    if (std.mem.eql(u8, name_val.toPtr().string, key)) return true;
                }
            }
        }
        return false;
    };
    // TDZ list available: only check that (not the full export names list),
    // so hoisted var/function exports without own properties are NOT TDZ.
    const n = tdz_arr.getArrayLength();
    var i: u32 = 0;
    var buf: [32]u8 = undefined;
    while (i < n) : (i += 1) {
        const idx_key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch return false;
        if (tdz_arr.get(idx_key)) |name_val| {
            if (name_val.bits != 0 and name_val.unbox() == .string) {
                if (std.mem.eql(u8, name_val.toPtr().string, key)) return true;
            }
        }
    }
    return false;
}

fn lessThanCodeUnit(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Exported names (own string keys of the backing exports), sorted ascending by
/// code unit — the order `[[OwnPropertyKeys]]` and `Object.keys` must observe.
/// Uses the export-names list when available (preferred), falling back to the
/// backing object's own keys.
pub fn sortedNames(arena: std.mem.Allocator, o: *JsObject) ![]const []const u8 {
    const b = backing(o) orelse return &.{};
    // Prefer the export-names list for deterministic order.
    if (exportNamesArr(b)) |arr| {
        const n = arr.getArrayLength();
        var names = try std.ArrayList([]const u8).initCapacity(arena, n);
        var i: u32 = 0;
        var buf: [32]u8 = undefined;
        while (i < n) : (i += 1) {
            const idx_key = std.fmt.bufPrint(&buf, "{d}", .{i}) catch break;
            if (arr.get(idx_key)) |name_val| {
                if (name_val.bits != 0 and name_val.unbox() == .string) {
                    names.appendAssumeCapacity(name_val.toPtr().string);
                }
            }
        }
        const out = try arena.alloc([]const u8, names.items.len);
        @memcpy(out, names.items);
        std.mem.sort([]const u8, out, {}, lessThanCodeUnit);
        return out;
    }
    const keys = b.ownKeys();
    const out = try arena.alloc([]const u8, keys.len);
    @memcpy(out, keys);
    std.mem.sort([]const u8, out, {}, lessThanCodeUnit);
    return out;
}
