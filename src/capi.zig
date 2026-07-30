// SPDX-License-Identifier: Apache-2.0
//! C ABI for embedding jsz from C, Rust, Go, or anything that speaks cdecl.
//! Mirrors the Zig API in root.zig (Isolate/Context/eval/Limits) behind
//! opaque handles. See include/jsz.h for the C-side declarations and
//! examples/embed.c for a runnable example.
//!
//! Memory contract:
//!   - jsz_eval copies the source string; the caller may free it immediately.
//!     (JS string values may alias evaluated source, so copies are retained
//!     until jsz_context_free.)
//!   - The string returned by jsz_last_string is owned by the context and
//!     valid until the next jsz_eval on that context (or jsz_context_free).
//!   - All handles are freed exactly once via their _free function.
const std = @import("std");
const jsz = @import("root.zig");

const calloc = std.heap.c_allocator;

/// Status codes returned by jsz_eval. Keep in sync with include/jsz.h.
const JSZ_OK: c_int = 0;
const JSZ_EXCEPTION: c_int = 1;
const JSZ_PARSE_ERROR: c_int = 2;
const JSZ_ERR_NOMEM: c_int = 3;

const CIsolate = struct {
    iso: jsz.Isolate,
};

const CContext = struct {
    ctx: *jsz.Context,
    /// Retained copies of every evaluated source (JS strings may alias them).
    sources: std.ArrayList([]u8) = .{},
    /// Display string of the last result / error message. c_allocator-owned.
    last_str: ?[:0]u8 = null,
    last_num: f64 = 0,
    last_is_num: bool = false,

    fn setLastString(self: *CContext, s: []const u8) void {
        if (self.last_str) |old| calloc.free(old);
        self.last_str = calloc.dupeZ(u8, s) catch null;
    }
};

export fn jsz_version() [*:0]const u8 {
    return jsz.version ++ "";
}

export fn jsz_isolate_new() ?*CIsolate {
    const ci = calloc.create(CIsolate) catch return null;
    ci.iso = jsz.Isolate.init(calloc) catch {
        calloc.destroy(ci);
        return null;
    };
    return ci;
}

export fn jsz_isolate_free(ci: ?*CIsolate) void {
    const c = ci orelse return;
    c.iso.deinit();
    calloc.destroy(c);
}

export fn jsz_context_new(ci: ?*CIsolate) ?*CContext {
    const c = ci orelse return null;
    const cc = calloc.create(CContext) catch return null;
    cc.* = .{ .ctx = c.iso.newContext() catch {
        calloc.destroy(cc);
        return null;
    } };
    return cc;
}

export fn jsz_context_free(cc: ?*CContext) void {
    const c = cc orelse return;
    c.ctx.deinit();
    for (c.sources.items) |s| calloc.free(s);
    c.sources.deinit(calloc);
    if (c.last_str) |s| calloc.free(s);
    calloc.destroy(c);
}

/// Resource limits for untrusted input; 0 = unlimited (see root.zig Limits).
export fn jsz_context_set_limits(cc: ?*CContext, mem_bytes: usize, gas: u64, time_ms: u64) void {
    const c = cc orelse return;
    c.ctx.setLimits(.{ .mem_bytes = mem_bytes, .gas = gas, .time_ms = time_ms });
}

/// Evaluate `src` (NUL-terminated). `name` is optional (NULL → "<eval>").
/// Returns JSZ_OK / JSZ_EXCEPTION / JSZ_PARSE_ERROR / JSZ_ERR_NOMEM; fetch
/// the result display string or error message via jsz_last_string.
export fn jsz_eval(cc: ?*CContext, src: ?[*:0]const u8, name: ?[*:0]const u8) c_int {
    const c = cc orelse return JSZ_ERR_NOMEM;
    const s = src orelse return JSZ_ERR_NOMEM;
    c.last_is_num = false;

    const copy = calloc.dupe(u8, std.mem.span(s)) catch return JSZ_ERR_NOMEM;
    c.sources.append(calloc, copy) catch {
        calloc.free(copy);
        return JSZ_ERR_NOMEM;
    };
    const src_name: []const u8 = if (name) |n| std.mem.span(n) else "<eval>";

    switch (c.ctx.eval(copy, src_name)) {
        .ok => |v| {
            var arena = std.heap.ArenaAllocator.init(calloc);
            defer arena.deinit();
            const disp = jsz.valueToDisplayString(arena.allocator(), v) catch "<value>";
            c.setLastString(disp);
            if (v.bits != 0) {
                const inner = @import("value/value.zig").Value{ .bits = v.bits };
                if (inner.unbox() == .number) {
                    c.last_num = v.toF64();
                    c.last_is_num = true;
                }
            }
            return JSZ_OK;
        },
        .exception => |e| {
            c.setLastString(e.message);
            return JSZ_EXCEPTION;
        },
        .parse_error => |e| {
            c.setLastString(e.message);
            return JSZ_PARSE_ERROR;
        },
    }
}

/// Display string of the last eval result (JSZ_OK) or the error message
/// (JSZ_EXCEPTION / JSZ_PARSE_ERROR). Owned by the context; valid until the
/// next jsz_eval on this context. NULL if nothing evaluated yet.
export fn jsz_last_string(cc: ?*CContext) ?[*:0]const u8 {
    const c = cc orelse return null;
    return if (c.last_str) |s| s.ptr else null;
}

/// If the last result was a number, writes it to out and returns true.
export fn jsz_last_number(cc: ?*CContext, out: ?*f64) bool {
    const c = cc orelse return false;
    if (!c.last_is_num) return false;
    if (out) |o| o.* = c.last_num;
    return true;
}

/// Force a full GC cycle on the context's isolate.
export fn jsz_gc(cc: ?*CContext) void {
    const c = cc orelse return;
    _ = c.ctx.gc();
}
