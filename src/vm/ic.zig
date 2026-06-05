// SPDX-License-Identifier: MIT
//! Inline cache table entry for property access sites.
const std = @import("std");

pub const IcState = enum { uninitialized, monomorphic, polymorphic, megamorphic };

pub const IcEntry = struct {
    shape: *anyopaque,
    slot: u32,
};

const POLY_CAP = 8;

pub const PROTO_IC_DEPTH = 5;
pub const ProtoGuard = struct { obj: *anyopaque, shape: *anyopaque };

pub const InlineCache = struct {
    state: IcState = .uninitialized,
    /// Property name this site specializes for (static GET_PROP/SET_PROP only).
    key: ?[]const u8 = null,
    mono: ?IcEntry = null,
    poly: [POLY_CAP]IcEntry = undefined,
    poly_len: u8 = 0,
    /// Lazily-allocated per-site map for megamorphic state (shape ptr → slot).
    mega: ?*std.AutoHashMapUnmanaged(*anyopaque, u32) = null,
    proto_recv_shape: ?*anyopaque = null,
    proto_slot: u32 = 0,
    proto_chain: [PROTO_IC_DEPTH]ProtoGuard = undefined,
    proto_chain_len: u8 = 0,

    /// True if this site has a proto-chain cache specialized for `key`.
    pub fn protoKeyMatches(self: *const InlineCache, key: []const u8) bool {
        return self.proto_chain_len != 0 and self.key != null and std.mem.eql(u8, self.key.?, key);
    }

    /// Record a proto-chain hit: walking `guards` from receiver.proto (guards[0])
    /// to the holder (guards[len-1]) resolves `key` at `slot`. No-op on key clash.
    pub fn protoRecord(self: *InlineCache, key: []const u8, recv_shape: *anyopaque, guards: []const ProtoGuard, slot: u32) void {
        if (guards.len == 0 or guards.len > PROTO_IC_DEPTH) return;
        if (self.key) |k| {
            if (!std.mem.eql(u8, k, key)) return;
        } else {
            self.key = key;
        }
        self.proto_recv_shape = recv_shape;
        self.proto_slot = slot;
        var i: usize = 0;
        while (i < guards.len) : (i += 1) self.proto_chain[i] = guards[i];
        self.proto_chain_len = @intCast(guards.len);
    }

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
            .megamorphic => blk: {
                if (self.mega) |m| break :blk m.get(shape);
                break :blk null;
            },
        };
    }

    pub fn record(self: *InlineCache, alloc: std.mem.Allocator, key: []const u8, shape: *anyopaque, slot: u32) void {
        // Key mismatch: reset to megamorphic regardless of current state.
        if (self.key == null) {
            self.key = key;
        } else if (!std.mem.eql(u8, self.key.?, key)) {
            self.state = .megamorphic;
            self.mono = null;
            self.poly_len = 0;
            self.mega = null;
            return;
        }

        // In megamorphic state with matching key: insert into the mega map.
        if (self.state == .megamorphic) {
            if (self.mega) |m| {
                m.put(alloc, shape, slot) catch {};
            }
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
                if (self.poly_len < POLY_CAP) {
                    self.poly[self.poly_len] = .{ .shape = shape, .slot = slot };
                    self.poly_len += 1;
                } else {
                    // Transition to megamorphic: build the mega map from all poly entries.
                    const m = alloc.create(std.AutoHashMapUnmanaged(*anyopaque, u32)) catch {
                        self.state = .megamorphic;
                        self.poly_len = 0;
                        return;
                    };
                    m.* = .{};
                    var j: u8 = 0;
                    while (j < self.poly_len) : (j += 1) {
                        m.put(alloc, self.poly[j].shape, self.poly[j].slot) catch {};
                    }
                    m.put(alloc, shape, slot) catch {};
                    self.mega = m;
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
    symbol,
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
    const alloc = std.testing.allocator;
    var ic = InlineCache{};
    defer {
        if (ic.mega) |m| {
            m.deinit(alloc);
            alloc.destroy(m);
        }
    }

    const key = "x";
    // 9 distinct shape pointers
    const s1: *anyopaque = @ptrFromInt(1);
    const s2: *anyopaque = @ptrFromInt(2);
    const s3: *anyopaque = @ptrFromInt(3);
    const s4: *anyopaque = @ptrFromInt(4);
    const s5: *anyopaque = @ptrFromInt(5);
    const s6: *anyopaque = @ptrFromInt(6);
    const s7: *anyopaque = @ptrFromInt(7);
    const s8: *anyopaque = @ptrFromInt(8);
    const s9: *anyopaque = @ptrFromInt(9);

    // (a) monomorphic after 1
    ic.record(alloc, key, s1, 0);
    try std.testing.expectEqual(IcState.monomorphic, ic.state);
    try std.testing.expectEqual(@as(?u32, 0), ic.lookup(key, s1));

    // (b) polymorphic after 2
    ic.record(alloc, key, s2, 1);
    try std.testing.expectEqual(IcState.polymorphic, ic.state);
    try std.testing.expectEqual(@as(?u32, 1), ic.lookup(key, s2));

    // (c) still polymorphic after 8 distinct shapes
    ic.record(alloc, key, s3, 2);
    ic.record(alloc, key, s4, 3);
    ic.record(alloc, key, s5, 4);
    ic.record(alloc, key, s6, 5);
    ic.record(alloc, key, s7, 6);
    ic.record(alloc, key, s8, 7);
    try std.testing.expectEqual(IcState.polymorphic, ic.state);
    try std.testing.expectEqual(@as(?u32, 6), ic.lookup(key, s7));

    // (d) megamorphic after 9th distinct shape
    ic.record(alloc, key, s9, 8);
    try std.testing.expectEqual(IcState.megamorphic, ic.state);

    // (e) lookup returns correct slot for shape recorded while megamorphic
    const s10: *anyopaque = @ptrFromInt(10);
    ic.record(alloc, key, s10, 99);
    try std.testing.expectEqual(@as(?u32, 99), ic.lookup(key, s10));
    // shapes recorded before megamorphic transition are also in the map
    try std.testing.expectEqual(@as(?u32, 8), ic.lookup(key, s9));
    try std.testing.expectEqual(@as(?u32, 7), ic.lookup(key, s8));
}

test "ArithCache defaults unknown mode" {
    const c = ArithCache{};
    try std.testing.expectEqual(ArithMode.unknown, c.mode);
}
