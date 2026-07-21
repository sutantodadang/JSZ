// SPDX-License-Identifier: Apache-2.0
//! R2: property access/mutation opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
//!
//! CRITICAL: getProp/setProp may invoke accessor getters/setters via bcInvokeJs,
//! which appends frames and can reallocate self.frames. Re-fetch frame via
//! self.frames.items[frame_idx] AFTER such calls — never use the stale `frame`.
const std = @import("std");
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const JsObject = @import("../../object/object.zig").JsObject;
const ic_mod = @import("../ic.zig");
const proxy_mod = @import("../../runtime/builtins/proxy.zig");
const namespace_mod = @import("../../runtime/builtins/namespace.zig");
const typed_array = @import("../../runtime/builtins/typed_array.zig");
const string_proto = @import("../../runtime/builtins/string_proto.zig");

/// ToPropertyKey's string half (ES §7.1.19): an object key first goes through
/// ToPrimitive(string) — running a user `@@toPrimitive`/`toString`/`valueOf`,
/// which may throw — before being stringified. Symbols are handled by the
/// callers' dedicated branches and never reach here.
fn toPropertyKeyString(self: *BcVm, key_val: Value) ![]const u8 {
    if (key_val.bits != 0 and bcv.isObjectOperand(key_val)) {
        if (try @import("../../runtime/builtins/coercion.zig").toPrimitive(self.arena, key_val, .string)) |p| {
            // ToPrimitive may yield a Symbol (via @@toPrimitive); such a key is a
            // symbol property, which the callers' symbol branch owns — but the
            // string form is the only channel here, so fall through to it.
            return bcv.valueToStringArena(self.arena, p);
        }
    }
    return bcv.valueToStringArena(self.arena, key_val);
}

/// TO_PROPERTY_KEY — materialize a member Reference's [[ReferencedName]] once.
/// Objects are coerced (running user code); primitives pass through so the dyn
/// get/set fast paths keep seeing numbers as numbers.
pub inline fn opToPropertyKey(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const sv = frame.registers[rsrc];
    if (!(sv.bits != 0 and bcv.isObjectOperand(sv))) {
        frame.registers[rdst] = sv;
        return null;
    }
    const prim = @import("../../runtime/builtins/coercion.zig").toPrimitive(self.arena, sv, .string) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in ToPropertyKey")) |oc| return oc;
        return null;
    };
    const key_val = if (prim) |p| blk: {
        // A @@toPrimitive that yields a Symbol produces a symbol key verbatim;
        // anything else stringifies.
        if (p.bits != 0 and p.unbox() == .symbol) break :blk p;
        break :blk try val_mod.makeString(self.arena, try bcv.valueToStringArena(self.arena, p));
    } else sv;
    // Re-fetch: the coercion may have appended frames and reallocated the slice.
    self.frames.items[self.frames.items.len - 1].registers[rdst] = key_val;
    return null;
}

/// A number Value → canonical array index (integer in [0, 2^32-2]), or null.
/// Lets `a[i]` reads/writes hit the dense integer path without stringifying `i`.
inline fn canonicalIndexFromValue(v: Value) ?u32 {
    if (v.bits == 0 or v.unbox() != .number) return null;
    const n = v.unbox().number;
    // `n >= 0` also rejects NaN; the upper bound excludes 2^32-1 (not a valid index).
    if (!(n >= 0) or n > 4294967294.0 or @trunc(n) != n) return null;
    return @intFromFloat(n);
}

/// Raise the strict-mode TypeError for a failed property assignment ([[Set]]
/// returned false). Returns a non-null RunOutcome only when the throw escapes
/// the current frame uncaught; null means a handler caught it.
fn strictAssignThrow(self: *BcVm) !?RunOutcome {
    const exc = try self.makeErrorObjectBc("TypeError", "Cannot assign to read only property");
    self.last_exception_value = exc;
    const found = try self.throwException(exc);
    if (!found) {
        const exc_msg = try bcv.formatExceptionMessage(self.arena, exc);
        return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc } };
    }
    return null;
}

/// RequireObjectCoercible for a source-level member read: reading a property
/// off `null`/`undefined` is a TypeError (ES EvaluatePropertyAccess... calls
/// `? RequireObjectCoercible(baseValue)`). Optional-chain reads short-circuit via
/// a JMP_IF_NULLISH guard before GET_PROP/GET_PROP_DYN, so a nullish base here is
/// always a genuine, non-optional access. Callers gate on `obj_val.isNullish()`
/// first. Returns null when a handler caught the throw (VM resumes at the catch);
/// a non-null RunOutcome when the exception escapes the current frame.
fn nullishReadThrow(self: *BcVm, obj_val: Value, key_desc: []const u8) !?RunOutcome {
    const kind: []const u8 = if (obj_val.isNull()) "null" else "undefined";
    const msg = try std.fmt.allocPrint(self.arena, "Cannot read properties of {s} (reading '{s}')", .{ kind, key_desc });
    const exc = try self.makeErrorObjectBc("TypeError", msg);
    self.last_exception_value = exc;
    const found = try self.throwException(exc);
    if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc } };
    return null;
}

/// PutValue step 5.a — ToObject(V.[[Base]]) throws a TypeError for a nullish
/// base, *after* the RHS has been evaluated (`null.x = f()` still calls `f`).
fn nullishWriteThrow(self: *BcVm, obj_val: Value, key_desc: []const u8) !?RunOutcome {
    const kind: []const u8 = if (obj_val.isNull()) "null" else "undefined";
    const msg = try std.fmt.allocPrint(self.arena, "Cannot set properties of {s} (setting '{s}')", .{ kind, key_desc });
    const exc = try self.makeErrorObjectBc("TypeError", msg);
    self.last_exception_value = exc;
    const found = try self.throwException(exc);
    if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc } };
    return null;
}

pub inline fn opGetProp(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const robj = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const key_val = frame.func.chunk.constants[kidx];
    const key = key_val.toPtr().string;
    const obj_val = frame.registers[robj];
    // A static-key `#x` member read is a PrivateElement [[Get]]: a missing brand
    // is a TypeError (never `undefined`), so it bypasses the ordinary IC/getProp
    // path entirely. (Computed `obj["#x"]` goes through opGetPropDyn and stays an
    // ordinary string-property read.)
    if (key.len > 0 and key[0] == '#') {
        const frame_idx = self.frames.items.len - 1;
        const result = self.privateGet(obj_val, key) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("private member access")) |oc| return oc;
            return null;
        };
        self.frames.items[frame_idx].registers[rdst] = result;
        return null;
    }
    // RequireObjectCoercible: `null.x` / `undefined.x` throws (non-optional read).
    if (obj_val.isNullish()) return nullishReadThrow(self, obj_val, key);
    const site_cache = &@constCast(frame.func.ic_table)[site_pc];
    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
        const obj = obj_val.toPtr().object;
        if (!obj.is_array and !std.mem.eql(u8, key, "length") and !std.mem.eql(u8, key, "size")) {
            if (site_cache.lookup(key, obj.shapePtr())) |slot| {
                if (obj.getOwnBySlot(obj.shapePtr(), slot)) |cached| {
                    if (self.ic_stats_enabled) self.ic_own_hits += 1;
                    frame.registers[rdst] = cached;
                    return null;
                }
            }
            // Proto-chain cache: method dispatch fast path (depth <= PROTO_IC_DEPTH).
            if (site_cache.protoKeyMatches(key) and site_cache.proto_recv_shape == obj.shapePtr()) {
                var cur: *JsObject = obj;
                var ok = true;
                var n: u8 = 0;
                while (n < site_cache.proto_chain_len) : (n += 1) {
                    const nxt = cur.proto orelse {
                        ok = false;
                        break;
                    };
                    const g = site_cache.proto_chain[n];
                    if (@as(*anyopaque, @ptrCast(nxt)) != g.obj or nxt.shapePtr() != g.shape) {
                        ok = false;
                        break;
                    }
                    cur = nxt;
                }
                if (ok) {
                    const hshape = site_cache.proto_chain[site_cache.proto_chain_len - 1].shape;
                    if (cur.getOwnBySlot(hshape, site_cache.proto_slot)) |cached| {
                        if (self.ic_stats_enabled) self.ic_proto_hits += 1;
                        frame.registers[rdst] = cached;
                        return null;
                    }
                }
            }
        }
    }

    if (self.ic_stats_enabled and obj_val.bits != 0 and obj_val.unbox() == .object) self.ic_misses += 1;
    const frame_idx = self.frames.items.len - 1;
    const result = self.getProp(obj_val, key) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in getter")) |oc| return oc;
        return null;
    };
    // Re-fetch frame: getProp may invoke a getter via bcInvokeJs which
    // appends to self.frames and potentially reallocates the backing slice.
    const frame2 = &self.frames.items[frame_idx];
    frame2.registers[rdst] = result;
    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
        const obj = obj_val.toPtr().object;
        if (!obj.is_array and !std.mem.eql(u8, key, "length") and !std.mem.eql(u8, key, "size")) {
            if (obj.resolveOwnSlot(key)) |slot| {
                if (!obj.attrAt(slot).is_accessor) site_cache.record(self.arena, key, obj.shapePtr(), slot);
            } else {
                // Walk proto chain; cache a hit within PROTO_IC_DEPTH links.
                var guards: [ic_mod.PROTO_IC_DEPTH]ic_mod.ProtoGuard = undefined;
                var cur = obj.proto;
                var n: usize = 0;
                while (cur) |c| {
                    if (n >= ic_mod.PROTO_IC_DEPTH) break;
                    guards[n] = .{ .obj = @ptrCast(c), .shape = c.shapePtr() };
                    if (c.resolveOwnSlot(key)) |pslot| {
                        if (!c.attrAt(pslot).is_accessor) site_cache.protoRecord(key, obj.shapePtr(), guards[0 .. n + 1], pslot);
                        break;
                    }
                    cur = c.proto;
                    n += 1;
                }
            }
        }
    }
    return null;
}

pub inline fn opGetPropDyn(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const robj = code[frame.pc];
    frame.pc += 1;
    const rkey = code[frame.pc];
    frame.pc += 1;
    const obj_val = frame.registers[robj];
    const key_val = frame.registers[rkey];
    // RequireObjectCoercible runs before ToPropertyKey (ES
    // EvaluatePropertyAccessWithExpressionKey): a nullish base throws even if the
    // key would otherwise be coerced via a user `toString`. Avoid coercing the key
    // for the message (that would run user code) — use its string form if present.
    if (obj_val.isNullish()) {
        const key_desc: []const u8 = if (key_val.bits != 0 and key_val.unbox() == .string)
            key_val.toPtr().string
        else
            "";
        return nullishReadThrow(self, obj_val, key_desc);
    }
    if (key_val.bits != 0 and key_val.unbox() == .string) {
        const key = key_val.toPtr().string;
        const site_cache = &@constCast(frame.func.ic_table)[site_pc];
        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
            const obj = obj_val.toPtr().object;
            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                if (site_cache.lookup(key, obj.shapePtr())) |slot| {
                    if (obj.getOwnBySlot(obj.shapePtr(), slot)) |cached| {
                        if (self.ic_stats_enabled) self.ic_own_hits += 1;
                        frame.registers[rdst] = cached;
                        return null;
                    }
                }
                if (site_cache.protoKeyMatches(key) and site_cache.proto_recv_shape == obj.shapePtr()) {
                    var cur: *JsObject = obj;
                    var ok = true;
                    var n: u8 = 0;
                    while (n < site_cache.proto_chain_len) : (n += 1) {
                        const nxt = cur.proto orelse {
                            ok = false;
                            break;
                        };
                        const g = site_cache.proto_chain[n];
                        if (@as(*anyopaque, @ptrCast(nxt)) != g.obj or nxt.shapePtr() != g.shape) {
                            ok = false;
                            break;
                        }
                        cur = nxt;
                    }
                    if (ok) {
                        const hshape = site_cache.proto_chain[site_cache.proto_chain_len - 1].shape;
                        if (cur.getOwnBySlot(hshape, site_cache.proto_slot)) |cached| {
                            if (self.ic_stats_enabled) self.ic_proto_hits += 1;
                            frame.registers[rdst] = cached;
                            return null;
                        }
                    }
                }
            }
        }
        if (self.ic_stats_enabled and obj_val.bits != 0 and obj_val.unbox() == .object) self.ic_misses += 1;
        const frame_idx_dyn = self.frames.items.len - 1;
        const result = self.getProp(obj_val, key) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in getter")) |oc| return oc;
            return null;
        };
        // Re-fetch frame after getProp: accessor getter dispatch via
        // bcInvokeJs may have appended frames and reallocated the slice.
        const frame2_dyn = &self.frames.items[frame_idx_dyn];
        frame2_dyn.registers[rdst] = result;
        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
            const obj = obj_val.toPtr().object;
            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                if (obj.resolveOwnSlot(key)) |slot| {
                    if (!obj.attrAt(slot).is_accessor) site_cache.record(self.arena, key, obj.shapePtr(), slot);
                } else {
                    var guards: [ic_mod.PROTO_IC_DEPTH]ic_mod.ProtoGuard = undefined;
                    var cur = obj.proto;
                    var n: usize = 0;
                    while (cur) |c| {
                        if (n >= ic_mod.PROTO_IC_DEPTH) break;
                        guards[n] = .{ .obj = @ptrCast(c), .shape = c.shapePtr() };
                        if (c.resolveOwnSlot(key)) |pslot| {
                            if (!c.attrAt(pslot).is_accessor) site_cache.protoRecord(key, obj.shapePtr(), guards[0 .. n + 1], pslot);
                            break;
                        }
                        cur = c.proto;
                        n += 1;
                    }
                }
            }
        }
    } else if (key_val.bits != 0 and key_val.unbox() == .symbol) {
        const fidx_sym = self.frames.items.len - 1;
        const sym_res = self.getPropSym(obj_val, key_val) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in getter")) |oc| return oc;
            return null;
        };
        self.frames.items[fidx_sym].registers[rdst] = sym_res;
    } else {
        // Numeric index on a dense array: return a present element with no key
        // stringification. A hole / out-of-range index falls through to the
        // proto-walking string path below (spec [[Get]]).
        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
            if (canonicalIndexFromValue(key_val)) |idx| {
                if (obj_val.toPtr().object.getIndexOwn(idx)) |v| {
                    frame.registers[rdst] = v;
                    return null;
                }
            }
        }
        const frame_idx_dyn2 = self.frames.items.len - 1;
        const key = toPropertyKeyString(self, key_val) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in ToPropertyKey")) |oc| return oc;
            return null;
        };
        const result_dyn2 = self.getProp(obj_val, key) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in getter")) |oc| return oc;
            return null;
        };
        self.frames.items[frame_idx_dyn2].registers[rdst] = result_dyn2;
    }
    return null;
}

pub inline fn opSetProp(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const robj = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rval = code[frame.pc];
    frame.pc += 1;
    const key_val = frame.func.chunk.constants[kidx];
    const key = key_val.toPtr().string;
    const obj_val = frame.registers[robj];
    const val = frame.registers[rval];
    if (obj_val.isNullish()) return nullishWriteThrow(self, obj_val, key);
    // A static-key `#x = v` write is a PrivateElement [[Set]]. Handle the private
    // accessor case here (invoke its setter, or TypeError when it has none);
    // everything else (a new field → PrivateFieldAdd, or updating an existing
    // writable field) falls through to the ordinary set path below, which also
    // flags the slot private via markPrivate.
    if (key.len > 0 and key[0] == '#') {
        // privateSet only runs user code (a setter) on its handled path, which
        // returns immediately; the fallthrough path is pure, so `frame` stays
        // valid below.
        const handled = self.privateSet(obj_val, key, val) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("private member write")) |oc| return oc;
            return null;
        };
        if (handled) return null;
    }
    // Save func pointer/strictness before setProp: a setter dispatch via
    // bcInvokeJs may reallocate self.frames, invalidating the `frame` pointer.
    const set_func = frame.func;
    const set_strict = frame.func.is_strict;
    const set_ok = self.setPropR(obj_val, key, val, obj_val) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in setter")) |oc| return oc;
        return null;
    };
    if (!set_ok and set_strict) {
        if (try strictAssignThrow(self)) |oc| return oc;
        return null;
    }
    // A static-key member write `obj.#x = v` (the only syntax that yields a
    // "#"-prefixed non-computed key) is a private class element: hide it from
    // reflection. Computed writes (`obj["#x"]`) go through opSetPropDyn and are
    // never marked, so a genuine string property named "#x" stays visible.
    if (set_ok and key.len > 0 and key[0] == '#' and obj_val.bits != 0) {
        const tag = obj_val.unbox();
        if (tag == .object) {
            obj_val.toPtr().object.markPrivate(key);
        } else if (tag == .bc_function) {
            const realm_mod = @import("../../runtime/realm.zig");
            if (realm_mod.active_context) |ctx| {
                if (try ctx.backingObject(self.arena, obj_val)) |bobj| bobj.markPrivate(key);
            }
        }
    }
    const site_cache = &@constCast(set_func.ic_table)[site_pc];
    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
        const obj = obj_val.toPtr().object;
        if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
            if (obj.resolveOwnSlot(key)) |slot| {
                site_cache.record(self.arena, key, obj.shapePtr(), slot);
            }
        }
    }
    return null;
}

/// DEFINE_PRIVATE: PrivateFieldAdd / PrivateMethodOrAccessorAdd. Same operand
/// encoding as SET_PROP, but *creates* the private element on the receiver
/// instead of routing through PrivateSet — so it neither requires an existing
/// element nor invokes a same-named private setter inherited from elsewhere.
/// Only the class desugaring emits it, always with a receiver it just created
/// (the instance under construction, or the class object itself for a static
/// element), so no user code can run here.
pub inline fn opDefinePrivate(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const robj = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rval = code[frame.pc];
    frame.pc += 1;
    const is_method = code[frame.pc] != 0;
    frame.pc += 1;
    const key = frame.func.chunk.constants[kidx].toPtr().string;
    const obj_val = frame.registers[robj];
    const val = frame.registers[rval];
    if (obj_val.bits == 0) return null;
    const holder: ?*@import("../../object/object.zig").JsObject = switch (obj_val.unbox()) {
        .object => |o| o,
        .bc_function => blk: {
            const realm_mod = @import("../../runtime/realm.zig");
            const ctx = realm_mod.active_context orelse break :blk null;
            break :blk try ctx.backingObject(self.arena, obj_val);
        },
        else => null,
    };
    const obj = holder orelse return null;
    // A private method is not writable: `obj.#m = v` must be a TypeError, which
    // `privateSet` derives from the stored attribute.
    _ = try obj.defineOwnData(key, val, .{ .writable = !is_method, .enumerable = false, .configurable = false, .is_private = true });
    obj.markPrivate(key);
    return null;
}

pub inline fn opSetPropDyn(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const site_pc = frame.pc - 1;
    const robj = code[frame.pc];
    frame.pc += 1;
    const rkey = code[frame.pc];
    frame.pc += 1;
    const rval = code[frame.pc];
    frame.pc += 1;
    const obj_val = frame.registers[robj];
    const key_val = frame.registers[rkey];
    const val = frame.registers[rval];
    if (obj_val.isNullish()) {
        const key_desc: []const u8 = if (key_val.bits != 0 and key_val.unbox() == .string)
            key_val.toPtr().string
        else
            "";
        return nullishWriteThrow(self, obj_val, key_desc);
    }
    if (key_val.bits != 0 and key_val.unbox() == .string) {
        const key = key_val.toPtr().string;
        const set_dyn_func = frame.func;
        const set_dyn_strict = frame.func.is_strict;
        const set_dyn_ok = self.setPropR(obj_val, key, val, obj_val) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in setter")) |oc| return oc;
            return null;
        };
        if (!set_dyn_ok and set_dyn_strict) {
            if (try strictAssignThrow(self)) |oc| return oc;
            return null;
        }
        const site_cache = &@constCast(set_dyn_func.ic_table)[site_pc];
        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
            const obj = obj_val.toPtr().object;
            if (!obj.is_array and !std.mem.eql(u8, key, "length")) {
                if (obj.resolveOwnSlot(key)) |slot| {
                    site_cache.record(self.arena, key, obj.shapePtr(), slot);
                }
            }
        }
    } else if (key_val.bits != 0 and key_val.unbox() == .symbol) {
        self.setPropSym(obj_val, key_val, val) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in setter")) |oc| return oc;
            return null;
        };
    } else {
        // Numeric index on a dense array: store by integer index, no key string.
        // For a real Array, [[Set]] bottoms out in the same ordinary element
        // store, and a dense array is always writable/extensible (it deopts
        // otherwise), so the write always succeeds — no strict-throw path needed.
        if (obj_val.bits != 0 and obj_val.unbox() == .object) {
            const o = obj_val.toPtr().object;
            if (o.is_array and o.usesDense()) {
                if (canonicalIndexFromValue(key_val)) |idx| {
                    o.setIndex(idx, val) catch |e| {
                        if (e != error.JsException) return e;
                        if (try self.raisePendingException("error in setter")) |oc| return oc;
                        return null;
                    };
                    return null;
                }
            }
        }
        const key = toPropertyKeyString(self, key_val) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in ToPropertyKey")) |oc| return oc;
            return null;
        };
        self.setProp(obj_val, key, val) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in setter")) |oc| return oc;
            return null;
        };
    }
    return null;
}

pub inline fn opDefineAccessor(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const robj = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const kind = code[frame.pc];
    frame.pc += 1;
    const rfn = code[frame.pc];
    frame.pc += 1;
    const key = frame.func.chunk.constants[kidx].toPtr().string;
    const obj_val = frame.registers[robj];
    const fn_val = frame.registers[rfn];
    if (obj_val.bits != 0 and obj_val.unbox() == .object) {
        const obj = obj_val.toPtr().object;
        const member: []const u8 = if (kind == 0) "get" else "set";
        if (obj.ownAccessorHolder(key)) |hv| {
            // Merge into the existing accessor holder for this key.
            try hv.toPtr().object.set(member, fn_val);
        } else {
            const holder_obj = if (self.heap) |heap|
                try JsObject.createOnHeap(heap, self.realm.object_prototype)
            else
                try JsObject.create(self.arena, self.realm.object_prototype);
            try holder_obj.set(member, fn_val);
            const holder_val = try val_mod.makeObject(self.arena, holder_obj);
            _ = try obj.defineOwnAccessor(key, holder_val, .{ .enumerable = true, .configurable = true });
        }
    }
    return null;
}

pub inline fn opDefineAccessorDyn(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const robj = code[frame.pc];
    frame.pc += 1;
    const rkey = code[frame.pc];
    frame.pc += 1;
    const kind = code[frame.pc];
    frame.pc += 1;
    const rfn = code[frame.pc];
    frame.pc += 1;
    const obj_val = frame.registers[robj];
    const key_val = frame.registers[rkey];
    const fn_val = frame.registers[rfn];
    if (obj_val.bits == 0 or obj_val.unbox() != .object) return null;
    const obj = obj_val.toPtr().object;
    const member: []const u8 = if (kind == 0) "get" else "set";
    if (key_val.bits != 0 and key_val.unbox() == .symbol) {
        if (obj.ownAccessorHolderSym(key_val)) |hv| {
            try hv.toPtr().object.set(member, fn_val);
        } else {
            const holder_obj = if (self.heap) |heap|
                try JsObject.createOnHeap(heap, self.realm.object_prototype)
            else
                try JsObject.create(self.arena, self.realm.object_prototype);
            try holder_obj.set(member, fn_val);
            const holder_val = try val_mod.makeObject(self.arena, holder_obj);
            _ = try obj.defineOwnAccessorSym(key_val, holder_val, .{ .enumerable = true, .configurable = true });
        }
        return null;
    }
    const key = try bcv.valueToStringArena(self.arena, key_val);
    if (obj.ownAccessorHolder(key)) |hv| {
        try hv.toPtr().object.set(member, fn_val);
    } else {
        const holder_obj = if (self.heap) |heap|
            try JsObject.createOnHeap(heap, self.realm.object_prototype)
        else
            try JsObject.create(self.arena, self.realm.object_prototype);
        try holder_obj.set(member, fn_val);
        const holder_val = try val_mod.makeObject(self.arena, holder_obj);
        _ = try obj.defineOwnAccessor(key, holder_val, .{ .enumerable = true, .configurable = true });
    }
    return null;
}

pub inline fn opGetThis(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = frame.this_val;
    return null;
}

pub inline fn opIn(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rkey = code[frame.pc];
    frame.pc += 1;
    const robj = code[frame.pc];
    frame.pc += 1;
    const key_v = frame.registers[rkey];
    const obj_v = frame.registers[robj];
    // Functions (native, bytecode, legacy) are objects — hasProperty handles
    // them; do NOT throw for any callable.
    const obj_is_valid = if (obj_v.bits == 0) false else switch (obj_v.unbox()) {
        .object, .native_function, .bc_function, .function => true,
        else => false,
    };
    if (!obj_is_valid) {
        const exc = try self.makeErrorObjectBc("TypeError", "Cannot use 'in' operator to search for key in a non-object");
        self.last_exception_value = exc;
        const found = try self.throwException(exc);
        if (!found) return RunOutcome{ .exception_value = .{ .msg = "Cannot use 'in' operator on a non-object", .value = exc } };
        return null;
    }
    const has = self.hasProperty(obj_v, key_v) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in proxy has trap")) |oc| return oc;
        return null;
    };
    self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, has);
    return null;
}

pub inline fn opDeleteProp(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const robj = code[frame.pc];
    frame.pc += 1;
    const rkey = code[frame.pc];
    frame.pc += 1;
    const obj_v = frame.registers[robj];
    const key_v = frame.registers[rkey];
    // ES `delete` §13.5.1.2 step 5.b: `baseObj := ? ToObject(ref.[[Base]])`, so
    // `delete null.x` / `delete undefined[k]` throws a TypeError. (Non-optional
    // member: optional `delete a?.b` short-circuits before DELETE_PROP.)
    if (obj_v.isNullish()) {
        const key_desc: []const u8 = if (key_v.bits != 0 and key_v.unbox() == .string)
            key_v.toPtr().string
        else
            "";
        return nullishReadThrow(self, obj_v, key_desc);
    }
    // Capture before deleteProperty: a Proxy/TypedArray trap can re-enter the VM
    // (invokeCallback grows self.frames, reallocating the backing array) which
    // invalidates `frame`. Read frame-derived state now; use indexed access after.
    const caller_is_strict = frame.func.is_strict;
    const ok = self.deleteProperty(obj_v, key_v) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error in proxy deleteProperty trap")) |oc| return oc;
        return null;
    };
    // Spec: strict-mode delete returning false → TypeError.
    if (!ok and caller_is_strict) {
        const exc = try self.makeErrorObjectBc("TypeError", "Cannot delete property in strict mode");
        self.last_exception_value = exc;
        const found = try self.throwException(exc);
        if (!found) {
            const exc_msg = try bcv.formatExceptionMessage(self.arena, exc);
            return RunOutcome{ .exception_value = .{ .msg = exc_msg, .value = exc } };
        }
        return null;
    }
    self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeBool(self.arena, ok);
    return null;
}

pub inline fn opGetKeys(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const robj = code[frame.pc];
    frame.pc += 1;
    const obj_val = frame.registers[robj];
    const arr_obj = if (self.heap) |heap|
        try JsObject.createOnHeap(heap, self.realm.array_prototype)
    else
        try JsObject.create(self.arena, self.realm.array_prototype);
    arr_obj.is_array = true;
    var count: u32 = 0;
    if (obj_val.bits != 0) {
        const iv = obj_val.unbox();
        if (iv == .object and iv.object.internal_kind == .proxy) {
            if (try proxy_mod.proxyOwnKeys(self.arena, iv.object)) |keys| {
                for (keys) |kv| {
                    if (kv.bits != 0 and kv.unbox() == .string) {
                        const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                        arr_obj.set(idx_str, kv) catch {};
                        count += 1;
                    }
                }
            }
        } else if (iv == .object) {
            // M16: Module Namespace — enumerable own string keys are the exported
            // names, sorted by code unit. [[Get]] is called for each export to
            // check TDZ (per [[GetOwnProperty]] step 4), which throws ReferenceError
            // for uninitialized bindings.
            if (iv.object.internal_kind == .module_namespace) {
                const names = try namespace_mod.sortedNames(self.arena, iv.object);
                for (names) |k| {
                    if (namespace_mod.isTDZ(iv.object, k)) {
                        // Per [[GetOwnProperty]] step 4, enumerating a namespace
                        // calls [[Get]] for each export; an uninitialized (TDZ)
                        // binding throws ReferenceError. Route through
                        // `throwException` (frame unwinding) so a JS try/catch
                        // around the for-in actually catches it — returning
                        // `error.JsException` raw bypasses the handler and the
                        // caller spins re-raising it (observed as OOM).
                        const realm_m = @import("../../runtime/realm.zig");
                        const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{k});
                        realm_m.pending_exception = try self.makeErrorObjectBc("ReferenceError", msg);
                        return try self.raisePendingException(msg);
                    }
                    const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                    const key_val2 = try val_mod.makeString(self.arena, k);
                    arr_obj.set(idx_str, key_val2) catch {};
                    count += 1;
                }
            } else {
                // TypedArray integer indices are enumerable own properties but are
                // exotic (not in the shape), so enumerate [0, length) first.
                if (iv.object.internal_kind == .typed_array) {
                    if (typed_array.getTd(obj_val)) |td| {
                        const len: usize = if (typed_array.taIsOob(td)) 0 else typed_array.taCurrentLen(td);
                        var i: usize = 0;
                        while (i < len) : (i += 1) {
                            const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                            const key_val2 = try std.fmt.allocPrint(self.arena, "{d}", .{i});
                            arr_obj.set(idx_str, try val_mod.makeString(self.arena, key_val2)) catch {};
                            count += 1;
                        }
                    }
                }
                // EnumerateObjectProperties (ES §14.7.5.10) walks the whole
                // prototype chain, not just own keys. A key already seen lower
                // down is skipped even when it was non-enumerable there, so a
                // non-enumerable own property shadows an enumerable inherited
                // one rather than letting it through.
                var visited = std.StringHashMap(void).init(self.arena);
                defer visited.deinit();
                var cur: ?*JsObject = iv.object;
                while (cur) |o| : (cur = o.proto) {
                    for (o.ownKeys()) |k| {
                        if (JsObject.isInternalSlotKey(k)) continue;
                        const gop = try visited.getOrPut(k);
                        if (gop.found_existing) continue;
                        if (!o.isEnumerable(k)) continue;
                        const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                        const key_val2 = try val_mod.makeString(self.arena, k);
                        arr_obj.set(idx_str, key_val2) catch {};
                        count += 1;
                    }
                }
            }
        } else if (iv == .string) {
            // for-in applies ToObject to its operand, so a primitive string
            // enumerates the index keys its String wrapper would expose.
            const units = string_proto.cuLen(iv.string);
            var i: usize = 0;
            while (i < units) : (i += 1) {
                const idx_str = try std.fmt.allocPrint(self.arena, "{d}", .{count});
                const key_val2 = try std.fmt.allocPrint(self.arena, "{d}", .{i});
                arr_obj.set(idx_str, try val_mod.makeString(self.arena, key_val2)) catch {};
                count += 1;
            }
        }
    }
    const len_val = try val_mod.makeNumber(self.arena, @floatFromInt(count));
    arr_obj.set("length", len_val) catch {};
    // Re-fetch frame: a proxy ownKeys trap may have run user code.
    self.frames.items[self.frames.items.len - 1].registers[rdst] = try val_mod.makeObject(self.arena, arr_obj);
    return null;
}
