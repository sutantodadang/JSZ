// SPDX-License-Identifier: Apache-2.0
//! ES2015 Symbol: factory, prototype methods, global registry.
const std = @import("std");
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;

/// Symbol([description]) — called, not constructed. Returns a unique symbol.
pub fn nativeSymbolCall(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    var desc: ?[]const u8 = null;
    if (args.len > 0 and args[0].bits != 0) {
        switch (args[0].unbox()) {
            .undefined_ => {},
            .string => |s| desc = try arena.dupe(u8, s),
            .number => |n| desc = try val_mod.formatNumber(arena, n),
            .boolean => |b| desc = if (b) "true" else "false",
            else => {},
        }
    }
    return val_mod.makeSymbol(arena, desc);
}

/// Symbol.prototype.toString() → "Symbol(desc)". `this` is the symbol.
pub fn nativeSymbolToString(arena: std.mem.Allocator, this_val: Value, _: []const Value) anyerror!Value {
    if (this_val.bits != 0 and this_val.unbox() == .symbol) {
        const sd = this_val.toPtr().symbol;
        const s = try std.fmt.allocPrint(arena, "Symbol({s})", .{sd.description orelse ""});
        return val_mod.makeString(arena, s);
    }
    return val_mod.makeString(arena, "Symbol()");
}

/// Global symbol registry for Symbol.for / Symbol.keyFor (single-threaded).
/// Its backing buffers + stored values live in the per-realm arena (see the
/// `append(arena, ...)` calls below). The registry is per-agent, so a fresh
/// realm must start empty — call `resetRegistry()` at realm setup. Without the
/// reset these globals dangle into the previous realm's freed arena, and the
/// next `Symbol.for` iterates / reallocs freed memory (a cross-realm
/// use-after-free that surfaces as a corrupt Value / segfault).
var registry_keys: std.ArrayListUnmanaged([]const u8) = .empty;
var registry_syms: std.ArrayListUnmanaged(Value) = .empty;

/// Reset the registry for a new realm. The old buffers are owned by the prior
/// realm's arena (freed with it), so dropping the structs is leak-free.
pub fn resetRegistry() void {
    registry_keys = .empty;
    registry_syms = .empty;
}

pub fn nativeSymbolFor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    const key: []const u8 = if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .string)
        args[0].toPtr().string
    else
        "undefined";
    for (registry_keys.items, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) return registry_syms.items[i];
    }
    const sym = try val_mod.makeSymbol(arena, try arena.dupe(u8, key));
    try registry_keys.append(arena, try arena.dupe(u8, key));
    try registry_syms.append(arena, sym);
    return sym;
}

pub fn nativeSymbolKeyFor(arena: std.mem.Allocator, _: Value, args: []const Value) anyerror!Value {
    if (args.len > 0 and args[0].bits != 0 and args[0].unbox() == .symbol) {
        const target = args[0].toPtr().symbol;
        for (registry_syms.items, 0..) |s, i| {
            if (s.bits != 0 and s.unbox() == .symbol and s.toPtr().symbol == target) {
                return val_mod.makeString(arena, registry_keys.items[i]);
            }
        }
    }
    return val_mod.makeUndefined(arena);
}
