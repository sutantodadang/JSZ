// SPDX-License-Identifier: Apache-2.0
//! Milestone 16 (ESM) — Phase 2: the Module Namespace Exotic Object (ES §10.4.6).
//!
//! `import * as ns from 'm'` binds `ns` to a namespace exotic object. It is a
//! thin exotic wrapper over the imported module's live exports object (the CJS
//! `exports` produced by the import/export desugar), stored in `internal_slot`:
//!
//!   * `[[Prototype]]` is null and the object is non-extensible.
//!   * `[[Get]]`(string) reads the *current* value of the named export (live),
//!     `undefined` for a non-export. Symbol keys are ordinary (`Symbol.toStringTag`
//!     is an own data property valued "Module").
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

/// Is `key` an exported name (an own string key of the backing exports)?
pub fn hasExport(o: *JsObject, key: []const u8) bool {
    const b = backing(o) orelse return false;
    return b.hasOwn(key);
}

fn lessThanCodeUnit(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Exported names (own string keys of the backing exports), sorted ascending by
/// code unit — the order `[[OwnPropertyKeys]]` and `Object.keys` must observe.
pub fn sortedNames(arena: std.mem.Allocator, o: *JsObject) ![]const []const u8 {
    const b = backing(o) orelse return &.{};
    const keys = b.ownKeys();
    const out = try arena.alloc([]const u8, keys.len);
    @memcpy(out, keys);
    std.mem.sort([]const u8, out, {}, lessThanCodeUnit);
    return out;
}
