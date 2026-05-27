// SPDX-License-Identifier: MIT
//! BcFunction and BcClosure: bytecode function representation for Phase 2.
const std = @import("std");
const Chunk = @import("./chunk.zig").Chunk;
const ic_mod = @import("../vm/ic.zig");

/// A compiled bytecode function. Owned by the compile arena.
pub const BcFunction = struct {
    name: ?[]const u8,
    arity: u16,
    chunk: Chunk,
    num_regs: u16,
    /// Nested function literals referenced by NEW_CLOSURE funcIdx.
    child_functions: []*BcFunction,
    /// Parameter names for binding into env on call.
    param_names: [][]const u8,
    /// Phase 4d: whether this function was compiled in strict mode.
    is_strict: bool = false,
    /// Phase 6: per-bytecode-site IC table, indexed by instruction PC.
    ic_table: []ic_mod.InlineCache,
    /// Phase 6: arithmetic fast-path feedback per instruction PC.
    arith_ic_table: []ic_mod.ArithCache,
    /// Phase 6: typeof feedback per instruction PC.
    typeof_ic_table: []ic_mod.TypeofCache,
    /// Phase 6: instanceof feedback per instruction PC.
    instanceof_ic_table: []ic_mod.InstanceofCache,
};

/// A closure: a BcFunction plus its captured environment pointer.
pub const BcClosure = struct {
    func: *const BcFunction,
    /// *Environment at definition site. Opaque to avoid circular import.
    env: *anyopaque,
};

test "BcFunction fields exist" {
    // Compilation check only.
    const dummy_chunk = @import("./chunk.zig").Chunk{
        .code = &[_]u8{},
        .constants = &[_]@import("../value/value.zig").Value{},
        .lines = &[_]u32{},
        .source_name = "<test>",
        .num_locals = 0,
    };
    const f = BcFunction{
        .name = null,
        .arity = 0,
        .chunk = dummy_chunk,
        .num_regs = 0,
        .child_functions = &[_]*BcFunction{},
        .param_names = &[_][]const u8{},
        .ic_table = &[_]ic_mod.InlineCache{},
        .arith_ic_table = &[_]ic_mod.ArithCache{},
        .typeof_ic_table = &[_]ic_mod.TypeofCache{},
        .instanceof_ic_table = &[_]ic_mod.InstanceofCache{},
    };
    try std.testing.expect(f.arity == 0);
}
