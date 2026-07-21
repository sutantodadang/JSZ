// SPDX-License-Identifier: Apache-2.0
//! R2: load/move/global/local opcode handlers extracted from `bc_vm.runLoop`.
//! Each handler is `pub inline fn` so the optimizer folds it back into the
//! dispatch switch — behaviour and codegen are identical to the inline arms.
//!
//! Contract: return `null` to continue the dispatch loop, or a `RunOutcome`
//! that `runLoop` must return directly (used for uncaught exceptions).
const std = @import("std");
const bcv = @import("../bc_vm.zig");
const BcVm = bcv.BcVm;
const BcCallFrame = bcv.BcCallFrame;
const RunOutcome = bcv.RunOutcome;
const val_mod = @import("../../value/value.zig");
const Value = val_mod.Value;
const Environment = @import("../../runtime/execution_context.zig").Environment;
const realm_mod = @import("../../runtime/realm.zig");

/// Resolve `name` as an own property of the running scope's global object
/// (`globalThis`). This backs the global-environment-record semantics: a binding
/// installed via `globalThis.x = v` (or otherwise added to the global object) is
/// visible as a bare identifier even though it was never declared as an
/// environment binding — and a ShadowRealm's evaluate runs against its own
/// `globalThis`, so the lookup is taken from the running frame's scope chain.
/// Only own data properties are consulted: inherited names (e.g. Object.prototype
/// members) must not leak in as globals, and accessors are skipped to keep the
/// failed-lookup path free of user code (and frame reallocation).
fn globalObjectOwn(frame: *BcCallFrame, name: []const u8) ?Value {
    const gt = frame.env.lookup("globalThis") catch return null;
    if (gt.bits == 0 or gt.unbox() != .object) return null;
    return gt.toPtr().object.getOwn(name);
}

/// ES §9.1.1.4 (global environment record): a `var`/function declaration (or a
/// sloppy implicit global assignment) at the top level of a Script becomes an
/// own property of the global object, observable as `globalThis.name`. We keep a
/// separate environment record for global bindings, so mirror the value onto the
/// `globalThis` object here. Only runs at true global scope (`parent == null`),
/// which naturally excludes block/catch/function-local bindings (those execute
/// in a child environment). Internal `__`-prefixed names are never exposed.
fn mirrorGlobalBinding(frame: *BcCallFrame, name: []const u8, value: Value, configurable: bool) void {
    mirrorGlobalBindingOpts(frame, name, value, configurable, false);
}

/// `declare_only` mirrors CreateGlobalVarBinding's "if the property already
/// exists, leave it (and its value) alone" clause — used by HOIST_VAR, which
/// only has to *reserve* the name at scope entry.
fn mirrorGlobalBindingOpts(frame: *BcCallFrame, name: []const u8, value: Value, configurable: bool, declare_only: bool) void {
    mirrorGlobalBindingOptsIn(frame, frame.env, name, value, configurable, declare_only);
}

/// As `mirrorGlobalBindingOpts`, but for a caller that already resolved which
/// environment record the binding was made in — the global object only mirrors
/// bindings that landed in the global record itself. (Eval code runs in a child
/// scope, so its own `frame.env` is never that record even when its `var`s are.)
fn mirrorGlobalBindingOptsIn(frame: *BcCallFrame, target: *Environment, name: []const u8, value: Value, configurable: bool, declare_only: bool) void {
    if (target.parent != null) return;
    // ES module top-level declarations live in the Module Environment Record
    // and must NOT become own-properties of the global object (spec §16.2.1.6).
    if (frame.func.is_module) return;
    if (name.len >= 2 and name[0] == '_' and name[1] == '_') return;
    const gt = frame.env.lookup("globalThis") catch return;
    if (gt.bits == 0 or gt.unbox() != .object) return;
    const obj = gt.toPtr().object;
    // Reassignment: just update the value, preserving the existing attributes
    // (a top-level `var`'s property is non-configurable; overwriting its
    // descriptor would either reject or wrongly flip configurable).
    if (obj.hasOwn(name)) {
        if (declare_only) return;
        obj.set(name, value) catch {};
        return;
    }
    // First definition. A declared `var`/function global in Script code is
    // non-configurable (DontDelete); one created by eval code, and a sloppy
    // implicit global, are configurable/deletable. All of them are enumerable
    // (CreateGlobalVarBinding/CreateGlobalFunctionBinding/CreateDataProperty),
    // unlike the non-enumerable built-in globals installed at realm setup.
    _ = obj.defineOwnData(name, value, .{ .writable = true, .enumerable = true, .configurable = configurable }) catch {};
}

pub inline fn opLoadK(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    frame.registers[rdst] = frame.func.chunk.constants[kidx];
    return null;
}

pub inline fn opLoadTrue(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeBool(self.arena, true);
    return null;
}

pub inline fn opLoadFalse(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeBool(self.arena, false);
    return null;
}

pub inline fn opLoadNull(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeNull(self.arena);
    return null;
}

pub inline fn opLoadUndef(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = try val_mod.makeUndefined(self.arena);
    return null;
}

pub inline fn opMove(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    frame.registers[rdst] = frame.registers[rsrc];
    return null;
}

pub inline fn opGetGlobal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    // `with` scopes (if any) shadow the lexical/global scope: an object whose
    // [[HasProperty]] is true provides the binding via [[Get]].
    if (frame.with_stack.items.len > 0) {
        if (try ownWith(self, frame, name)) |wobj| {
            // The [[Get]] runs a getter (re-entrant) → self.frames can realloc,
            // leaving `frame` dangling. Write through the re-fetched top frame.
            const v = try self.getProp(wobj, name);
            self.frames.items[self.frames.items.len - 1].registers[rdst] = v;
            return null;
        }
    }
    // Look up in frame env (chains to global), then realm global.
    // An identifier that resolves nowhere is a ReferenceError
    // (env lookups run no user code, so no frame realloc here).
    // TemporalDeadZone is also a ReferenceError but with a specific message.
    if (frame.env.lookupUntil(name, frame.inherited_env_floor)) |v| {
        frame.registers[rdst] = v;
    } else |err| switch (err) {
        error.TemporalDeadZone => {
            const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
            const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        },
        error.ConstAssignment => unreachable, // Can't happen on lookup
        error.NotDefined => {
            if (try inheritedWith(self, frame, name)) |wobj| {
                const v = try self.getProp(wobj, name);
                self.frames.items[self.frames.items.len - 1].registers[rdst] = v;
                return null;
            }
            if (frame.inherited_env_floor != null) {
                if (frame.env.lookup(name)) |v| {
                    frame.registers[rdst] = v;
                    return null;
                } else |_| {}
            }
            if (self.realm.global_env.lookup(name)) |v| {
                frame.registers[rdst] = v;
            } else |_| if (globalObjectOwn(frame, name)) |v| {
                frame.registers[rdst] = v;
            } else {
                const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{name});
                const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
                self.last_exception_value = exc_val;
                const found = try self.throwException(exc_val);
                if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
            }
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
    return null;
}

pub inline fn opGetGlobalOpt(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    // Tolerant load for `typeof <identifier>`: undeclared => undefined.
    // TDZ still throws — even typeof respects TDZ.
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    const lookup = frame.env.lookup(name);
    if (lookup) |v| {
        frame.registers[rdst] = v;
    } else |err| switch (err) {
        error.TemporalDeadZone => {
            // typeof respects TDZ — throw the error.
            const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
            const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        },
        error.ConstAssignment => unreachable,
        error.NotDefined => {
            frame.registers[rdst] = self.realm.global_env.lookup(name) catch
                globalObjectOwn(frame, name) orelse
                try val_mod.makeUndefined(self.arena);
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
    return null;
}

pub inline fn opHoistVar(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const undef = try val_mod.makeUndefined(self.arena);
    // EvalDeclarationInstantiation binds a `var`/function name into the running
    // context's *VariableEnvironment*, not its LexicalEnvironment. For function
    // and Script code those coincide, but sloppy eval runs in a fresh
    // declarative scope whose vars belong to the enclosing function (or the
    // global record) — so hoist into `varScope()`, which stops at that scope.
    const var_env = frame.env.varScope();
    var_env.hoistVar(name, undef) catch return error.OutOfMemory;
    // ES §9.1.1.4.17 CreateGlobalVarBinding: a top-level `var`/function name in
    // Script or eval code reserves an own property of the global object at
    // declaration-instantiation time, even when it is never assigned (`var x;`
    // still yields `globalThis.x === undefined`). Bindings introduced by eval
    // are deletable; Script-level ones are not.
    mirrorGlobalBindingOptsIn(frame, var_env, name, undef, frame.func.is_eval, true);
    return null;
}

pub inline fn opHoistLexical(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const undef = try val_mod.makeUndefined(self.arena);
    // Declare as uninitialized lexical binding (TDZ).
    frame.env.defineLexical(name, .let, false, undef) catch return error.OutOfMemory;
    return null;
}

pub inline fn opInitLexical(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const is_const = code[frame.pc] != 0;
    frame.pc += 1;
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const value = frame.registers[rsrc];
    // Initialize the existing lexical binding (take out of TDZ).
    frame.env.initialize(name, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotDefined => {
            // Fallback: define as a regular var-like binding if not found.
            // This handles cases where the binding was declared in a different
            // environment frame (e.g., module scope).
            frame.env.define(name, value) catch return error.OutOfMemory;
        },
        error.TemporalDeadZone => unreachable, // INIT_LEX should only target declared-but-uninitialized bindings
        error.ConstAssignment => unreachable, // INIT_LEX is not an assignment
    };
    // Upgrade binding to const_ so subsequent assignments throw TypeError.
    if (is_const) frame.env.upgradeToConst(name);
    return null;
}

pub inline fn opEnterScope(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    // Push a fresh child environment for a block scope. Lexical bindings
    // declared inside the block live here and are discarded on EXIT_SCOPE,
    // giving correct block scoping (shadowing) and per-iteration freshness.
    frame.env = Environment.init(self.arena, frame.env) catch return error.OutOfMemory;
    return null;
}

pub inline fn opExitScope(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    if (frame.env.parent) |p| frame.env = p;
    return null;
}

pub inline fn opPushWith(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const robj = code[frame.pc];
    frame.pc += 1;
    const obj = frame.registers[robj];
    // `with (expr)` runs ToObject(expr) before entering the scope, so a nullish
    // head is a TypeError rather than a with-scope that matches nothing.
    if (obj.bits == 0 or obj.unbox() == .null_ or obj.unbox() == .undefined_) {
        realm_mod.pending_exception = try self.makeErrorObjectBc("TypeError", "Cannot convert undefined or null to object");
        if (try self.raisePendingException("with")) |oc| return oc;
        return null;
    }
    frame.with_stack.append(self.arena, obj) catch return error.OutOfMemory;
    return null;
}

pub inline fn opPopWith(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    if (frame.with_stack.items.len > 0) _ = frame.with_stack.pop();
    return null;
}

/// Object Environment Record HasBinding(N) for a `with`-object (spec 9.1.1.2.1):
/// HasProperty(obj, N) AND, unless the @@unscopables map lists N as truthy, the
/// binding applies. A with-object whose `obj[@@unscopables][N]` is truthy hides
/// N from the with-scope so resolution falls through to the outer environment.
/// Note: both HasProperty and the @@unscopables Get can run user code.
pub fn withHasBinding(self: *BcVm, wobj: Value, key: Value, name: []const u8) !bool {
    if (!try self.hasProperty(wobj, key)) return false;
    const unsym = realm_mod.active_sym_unscopables orelse return true;
    const unsc = try self.getPropSym(wobj, unsym);
    if (unsc.bits == 0 or unsc.unbox() != .object) return true;
    const blocked = try self.getProp(unsc, name);
    return !val_mod.toBoolean(blocked);
}

/// The first with-object in `frame.with_stack[lo..hi]` (searched innermost-first)
/// that provides a binding for `name`, or null. Splitting the stack lets callers
/// consult the frame's OWN with-scopes before its environment and the ones
/// inherited from the closure's definition site after it — an inherited scope
/// encloses the callee, so it must not shadow the callee's own parameters and
/// locals. Only the HasProperty/@@unscopables of a scanned object runs user code.
fn withScan(self: *BcVm, frame: *BcCallFrame, name: []const u8, lo: usize, hi: usize) !?Value {
    if (lo >= hi) return null;
    const key = try val_mod.makeString(self.arena, name);
    var i = hi;
    while (i > lo) {
        i -= 1;
        const wobj = frame.with_stack.items[i];
        if (wobj.bits == 0 or wobj.unbox() != .object) continue;
        if (try withHasBinding(self, wobj, key, name)) return wobj;
    }
    return null;
}

/// The with-scopes entered by this frame itself (they shadow everything).
inline fn ownWith(self: *BcVm, frame: *BcCallFrame, name: []const u8) !?Value {
    return withScan(self, frame, name, frame.inherited_with, frame.with_stack.items.len);
}

/// The with-scopes inherited from the callee's definition site (they sit outside
/// the frame's own environment).
inline fn inheritedWith(self: *BcVm, frame: *BcCallFrame, name: []const u8) !?Value {
    return withScan(self, frame, name, 0, frame.inherited_with);
}

pub inline fn opSetGlobal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    const value = frame.registers[rsrc];
    const cur_is_strict = frame.func.is_strict;
    // `with` scopes: assign through an object whose [[HasProperty]] is true.
    if (frame.with_stack.items.len > 0) {
        if (try ownWith(self, frame, name)) |wobj| {
            try self.setProp(wobj, name, value);
            return null;
        }
    }
    // Try to assign in env chain (covers locals and upvalues).
    // TemporalDeadZone and ConstAssignment are real errors that must propagate.
    frame.env.assignUntil(name, value, frame.inherited_env_floor) catch |err| {
        switch (err) {
        error.TemporalDeadZone => {
            const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
            const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        },
        error.ConstAssignment => {
            const msg = try std.fmt.allocPrint(self.arena, "Assignment to constant variable.", .{});
            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        },
        error.NotDefined => {
            // Not found in the environment chain: an object environment record
            // inherited from the function's definition site still encloses it,
            // and PutValue writes through it before reaching the global object.
            if (try inheritedWith(self, frame, name)) |wobj| {
                try self.setProp(wobj, name, value);
                return null;
            }
            if (frame.inherited_env_floor != null) {
                if (frame.env.assign(name, value)) |_| {
                    mirrorGlobalBinding(frame, name, value, true);
                    return null;
                } else |_| {}
            }
            if (cur_is_strict) {
                // Phase 4d: strict mode — undeclared variable assignment is a ReferenceError.
                const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{name});
                const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
                self.last_exception_value = exc_val;
                const found = try self.throwException(exc_val);
                if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
            } else if (frame.env.parent == null) {
                // Already at global env — sloppy implicit global (deletable).
                frame.env.define(name, value) catch return error.OutOfMemory;
            } else {
                // Sloppy-mode implicit global: write reaches the global object, not a
                // local binding (spec §8.1.1.4.11 PutValue). Handles cross-realm functions
                // whose frame.env chains to a foreign realm's global env — `globalThis`
                // there is that realm's global object.
                const wrote = blk: {
                    const gt = frame.env.lookup("globalThis") catch break :blk false;
                    if (gt.bits == 0 or gt.unbox() != .object) break :blk false;
                    gt.toPtr().object.set(name, value) catch break :blk false;
                    break :blk true;
                };
                if (!wrote) frame.env.define(name, value) catch return error.OutOfMemory;
            }
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
};
    // Keep the global object in sync when assigning a global binding (covers
    // both reassignment of an existing global and sloppy implicit-global
    // creation). A freshly created implicit global is configurable/deletable;
    // a reassignment preserves the existing (var → non-configurable) descriptor.
    mirrorGlobalBinding(frame, name, value, true);
    return null;
}

pub inline fn opDefineGlobal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    // Phase 4d: always define (never throws ReferenceError in strict mode).
    // Used for var declarations, catch-variable bindings, function declarations.
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const name_val = frame.func.chunk.constants[kidx];
    const name = name_val.toPtr().string;
    const value = frame.registers[rsrc];
    // Try assign first (update existing binding), else define.
    frame.env.assign(name, value) catch {
        if (frame.env.parent == null) {
            frame.env.define(name, value) catch return error.OutOfMemory;
        } else {
            frame.env.define(name, value) catch return error.OutOfMemory;
        }
    };
    // Top-level `var`/function declarations are also own properties of the
    // global object (observable as `globalThis.name`). Script-level ones are
    // non-configurable (DontDelete) — `delete globalThis.x` returns false —
    // while eval-introduced ones are deletable (EvalDeclarationInstantiation
    // passes varEnv.CreateGlobal{Var,Function}Binding a `true` deletable flag).
    mirrorGlobalBinding(frame, name, value, frame.func.is_eval);
    return null;
}

/// As `mirrorGlobalBinding`, for a caller that already resolved which
/// environment record the binding was made in.
fn mirrorGlobalBindingIn(frame: *BcCallFrame, target: *Environment, name: []const u8, value: Value, configurable: bool) void {
    if (target.parent != null) return;
    if (frame.func.is_module) return;
    if (name.len >= 2 and name[0] == '_' and name[1] == '_') return;
    const gt = frame.env.lookup("globalThis") catch return;
    if (gt.bits == 0 or gt.unbox() != .object) return;
    const obj = gt.toPtr().object;
    if (obj.hasOwn(name)) {
        obj.set(name, value) catch {};
        return;
    }
    _ = obj.defineOwnData(name, value, .{ .writable = true, .enumerable = false, .configurable = configurable }) catch {};
}

/// DEFINE_LOCAL: declare a block/function-scoped `let`/`const`.
pub inline fn opDefineLocal(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    frame.env.define(name, frame.registers[rsrc]) catch return error.OutOfMemory;
    return null;
}

/// Annex B.3.3: propagate a block-scoped function declaration's current value
/// to the enclosing variable environment.
pub inline fn opSyncAnnexBFn(_: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const value = frame.env.lookup(name) catch return null;
    const target = frame.env.varScope();
    target.assign(name, value) catch return null;
    mirrorGlobalBindingIn(frame, target, name, value, false);
    return null;
}

/// `delete <identifier>` (ES `delete` on an environment Reference). Resolves the
/// name over the scope chain WITHOUT evaluating its value, and stores the boolean
/// result in Rdst. See the DELETE_NAME opcode doc for the full precedence.
pub inline fn opDeleteName(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const frame_idx = self.frames.items.len - 1;

    // 1) `with` scopes shadow the lexical/global scope: delete from the first
    //    with-object whose [[HasProperty]] is true (a Proxy trap here can re-enter
    //    the VM and reallocate self.frames — index back in afterwards).
    if (frame.with_stack.items.len > 0) {
        if (try ownWith(self, frame, name)) |wobj| {
            const key = try val_mod.makeString(self.arena, name);
            const res = self.deleteProperty(wobj, key) catch |e| {
                if (e != error.JsException) return e;
                if (try self.raisePendingException("error in deleteProperty trap")) |oc| return oc;
                return null;
            };
            self.frames.items[frame_idx].registers[rdst] = try val_mod.makeBool(self.arena, res);
            return null;
        }
    }

    // 2) Environment record binding. A local/lexical declarative binding is
    //    non-deletable (false). A global object-record binding (var/function/
    //    implicit/builtin) defers to the global object's [[Delete]] below.
    const classify = frame.env.deleteName(name);
    if (classify == .not_deletable) {
        frame.registers[rdst] = try val_mod.makeBool(self.arena, false);
        return null;
    }
    // No declarative binding: an object environment record inherited from this
    // function's definition site is still in scope, outside the frame's own.
    if (classify == .not_found) {
        if (try inheritedWith(self, frame, name)) |wobj| {
            const key = try val_mod.makeString(self.arena, name);
            const res = self.deleteProperty(wobj, key) catch |e| {
                if (e != error.JsException) return e;
                if (try self.raisePendingException("error in deleteProperty trap")) |oc| return oc;
                return null;
            };
            self.frames.items[frame_idx].registers[rdst] = try val_mod.makeBool(self.arena, res);
            return null;
        }
    }

    // 3) Global object [[Delete]] — reached for `.global_object_ref` bindings and
    //    for `.not_found` names that are nonetheless own properties of the global
    //    object (built-ins, `globalThis.x = …`). Honors configurability: a
    //    non-configurable global (a `var`/function declaration, NaN/Infinity) → false;
    //    a configurable one (builtin object, implicit global) → true and removed.
    if (frame.env.lookup("globalThis")) |gt| {
        if (gt.bits != 0 and gt.unbox() == .object and gt.toPtr().object.hasOwn(name)) {
            const key = try val_mod.makeString(self.arena, name);
            const res = self.deleteProperty(gt, key) catch |e| {
                if (e != error.JsException) return e;
                if (try self.raisePendingException("error in deleteProperty")) |oc| return oc;
                return null;
            };
            // Keep the environment record in sync when the object property is gone.
            if (res) self.frames.items[frame_idx].env.removeGlobalBinding(name);
            self.frames.items[frame_idx].registers[rdst] = try val_mod.makeBool(self.arena, res);
            return null;
        }
    } else |_| {}

    // 4) Object-record binding with no global-object property (shouldn't normally
    //    happen), or an unresolvable reference → true.
    if (classify == .global_object_ref) frame.env.removeGlobalBinding(name);
    frame.registers[rdst] = try val_mod.makeBool(self.arena, true);
    return null;
}

pub inline fn opGetLocal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const slot = code[frame.pc];
    frame.pc += 1;
    // GET_LOCAL reads from registers[slot]. Also sync from env if defined there.
    frame.registers[rdst] = frame.registers[slot];
    return null;
}

pub inline fn opSetLocal(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const slot = code[frame.pc];
    frame.pc += 1;
    const rsrc = code[frame.pc];
    frame.pc += 1;
    frame.registers[slot] = frame.registers[rsrc];
    return null;
}
