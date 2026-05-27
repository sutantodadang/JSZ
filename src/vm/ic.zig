// SPDX-License-Identifier: MIT
//! Inline cache table entry for property access sites.
const std = @import("std");

pub const IcState = enum { uninitialized, monomorphic, polymorphic, megamorphic };

pub const IcEntry = struct {
    shape: *anyopaque,
    slot: u32,
};

pub const InlineCache = struct {
    state: IcState = .uninitialized,
    /// Property name this site specializes for (static GET_PROP/SET_PROP only).
    key: ?[]const u8 = null,
    mono: ?IcEntry = null,
    poly: [4]IcEntry = undefined,
    poly_len: u8 = 0,

    pub fn lookup(self: *const InlineCache, key: []const u8, shape: *anyopaque) ?u32 {
        if (self.key == null or !std.mem.eql(u8, self.key.?, key)) return null;
        return switch (self.state) {
            .uninitialized => null,
            .monomorphic => blk: {
                if (self.mono) |m| {
                    if (m.shape == shape) break :blk m.slot;
                }
                break :blk null;
            },
            .polymorphic => blk: {
                var i: u8 = 0;
                while (i < self.poly_len) : (i += 1) {
                    const p = self.poly[i];
                    if (p.shape == shape) break :blk p.slot;
                }
                break :blk null;
            },
            .megamorphic => null,
        };
    }

    pub fn record(self: *InlineCache, key: []const u8, shape: *anyopaque, slot: u32) void {
        if (self.state == .megamorphic) return;
        if (self.key == null) self.key = key;
        if (!std.mem.eql(u8, self.key.?, key)) {
            self.state = .megamorphic;
            self.mono = null;
            self.poly_len = 0;
            return;
        }

        switch (self.state) {
            .uninitialized => {
                self.mono = .{ .shape = shape, .slot = slot };
                self.state = .monomorphic;
            },
            .monomorphic => {
                if (self.mono) |m| {
                    if (m.shape == shape) return;
                    self.poly[0] = m;
                    self.poly[1] = .{ .shape = shape, .slot = slot };
                    self.poly_len = 2;
                    self.mono = null;
                    self.state = .polymorphic;
                }
            },
            .polymorphic => {
                var i: u8 = 0;
                while (i < self.poly_len) : (i += 1) {
                    if (self.poly[i].shape == shape) return;
                }
                if (self.poly_len < self.poly.len) {
                    self.poly[self.poly_len] = .{ .shape = shape, .slot = slot };
                    self.poly_len += 1;
                } else {
                    self.state = .megamorphic;
                    self.poly_len = 0;
                }
            },
            .megamorphic => {},
        }
    }
};

pub const ArithMode = enum(u8) {
    unknown,
    number_pair,
};

pub const ArithCache = struct {
    mode: ArithMode = .unknown,
};

pub const TypeofTag = enum(u8) {
    undefined_,
    null_,
    boolean,
    number,
    string,
    function_like,
    object_like,
};

pub const TypeofCache = struct {
    initialized: bool = false,
    tag: TypeofTag = .undefined_,
    shape: ?*anyopaque = null,
    result: []const u8 = "undefined",
};

pub const InstanceofCache = struct {
    initialized: bool = false,
    rhs_obj: ?*anyopaque = null,
    target_proto: ?*anyopaque = null,
};

test "IC transitions mono to poly to mega" {
    var ic = InlineCache{};
    const key = "x";
    const a: *anyopaque = @ptrFromInt(1);
    const b: *anyopaque = @ptrFromInt(2);
    const c: *anyopaque = @ptrFromInt(3);
    const d: *anyopaque = @ptrFromInt(4);
    const e: *anyopaque = @ptrFromInt(5);

    ic.record(key, a, 0);
    try std.testing.expectEqual(IcState.monomorphic, ic.state);
    try std.testing.expectEqual(@as(?u32, 0), ic.lookup(key, a));

    ic.record(key, b, 1);
    try std.testing.expectEqual(IcState.polymorphic, ic.state);
    try std.testing.expectEqual(@as(?u32, 1), ic.lookup(key, b));

    ic.record(key, c, 2);
    ic.record(key, d, 3);
    ic.record(key, e, 4);
    try std.testing.expectEqual(IcState.megamorphic, ic.state);
}

test "ArithCache defaults unknown mode" {
    const c = ArithCache{};
    try std.testing.expectEqual(ArithMode.unknown, c.mode);
}
