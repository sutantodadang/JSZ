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

/// True for the runtime/ESM-desugar helper globals that the CommonJS/module
/// prelude installs via DEFINE_GLOBAL in *script* context. These must stay
/// invisible on `globalThis` (they are engine internals, not user declarations).
/// A USER top-level `var`/function whose name merely starts with `__` (e.g. the
/// legacy test262 `__func`/`__MONSTER` idiom) is NOT reserved and mirrors to the
/// global object normally — so `delete __func` correctly returns false.
fn isReservedRuntimeGlobal(name: []const u8) bool {
    if (name.len < 3 or name[0] != '_' or name[1] != '_') return false;
    const reserved = [_][]const u8{
        "__modules__",       "__module_id__",      "__moduleStatus__",   "__moduleGraph__",
        "__moduleUnresolved__", "__exportStar__",  "__exportStarGetter__", "__starRoot__",
        "__ambMap__",        "__deferGather__",    "__liveReexport__",   "__liveLocalExport__",
        "__readyForSync__",  "__esm_hoist_point__", "__esm_hoist_point_no_se__", "__awaitDeps__",
        "__entry__",         "__initExports__",    "__initModuleExports__", "__evalError__",
        "__jszModuleReject__", "__import_meta__",  "__backing__",
    };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }
    return false;
}

/// Resolve `name` as an own property of the running scope's global object
/// (`globalThis`). This backs the global-environment-record semantics: a binding
/// installed via `globalThis.x = v` (or otherwise added to the global object) is
/// visible as a bare identifier even though it was never declared as an
/// environment binding — and a ShadowRealm's evaluate runs against its own
/// `globalThis`, so the lookup is taken from the running frame's scope chain.
/// Only own data properties are consulted: inherited names (e.g. Object.prototype
/// members) must not leak in as globals, and accessors are skipped to keep the
/// failed-lookup path free of user code (and frame reallocation).
/// Identifier resolution against the global object Environment Record: when the
/// global object carries `name` as an own property, resolve it via a full
/// [[Get]] (so an accessor property's getter runs) rather than reading the raw
/// slot. Returns null when the global object has no such own property, so the
/// caller can fall through to a ReferenceError. `getProp` may run a getter
/// (re-entrant → `self.frames` can realloc), so the caller must re-fetch the
/// frame before writing the destination register.
fn globalObjectGet(self: *BcVm, frame: *BcCallFrame, name: []const u8) !?Value {
    const gt = frame.env.lookup("globalThis") catch return null;
    if (gt.bits == 0 or gt.unbox() != .object) return null;
    if (!gt.toPtr().object.hasOwn(name)) return null;
    return try self.getProp(gt, name);
}

/// ES §9.1.1.4 (global environment record): a `var`/function declaration (or a
/// sloppy implicit global assignment) at the top level of a Script becomes an
/// own property of the global object, observable as `globalThis.name`. We keep a
/// separate environment record for global bindings, so mirror the value onto the
/// `globalThis` object here. Only runs when the frame's *variable* environment is
/// the global one, which naturally excludes function-local bindings while still
/// covering a `var` inside a block/catch and a sloppy direct eval nested in global
/// code. Internal `__`-prefixed names are never exposed.
fn mirrorGlobalBinding(frame: *BcCallFrame, name: []const u8, value: Value, configurable: bool) void {
    mirrorGlobalBindingOpts(frame, name, value, configurable, false);
}

/// The environment record a `var`/function declaration made by this frame binds
/// into. Ordinary code binds in its own scope; non-strict eval code hoists into
/// the enclosing VariableEnvironment instead (§19.2.1.3 EvalDeclarationInstantiation
/// runs its var-scoped instantiation against `varEnv`, the calling context's
/// VariableEnvironment, while `let`/`const` stay in the eval's own `lexEnv`).
/// `Environment.varScope` already stops at the eval scope itself for a *strict*
/// eval, whose vars are confined to it.
inline fn varTargetEnv(frame: *BcCallFrame) *Environment {
    return if (frame.func.is_eval) frame.env.varScope() else frame.env;
}

/// `declare_only` mirrors CreateGlobalVarBinding's "if the property already
/// exists, leave it (and its value) alone" clause — used by HOIST_VAR, which
/// only has to *reserve* the name at scope entry.
fn mirrorGlobalBindingOpts(frame: *BcCallFrame, name: []const u8, value: Value, configurable: bool, declare_only: bool) void {
    mirrorGlobalBindingOptsIn(frame, varTargetEnv(frame), name, value, configurable, declare_only);
}

/// As `mirrorGlobalBindingOpts`, but for callers that already resolved the target
/// environment record — the global object only mirrors bindings that landed in
/// the global record itself (eval's `varScope()` returns the enclosing record).
fn mirrorGlobalBindingOptsIn(frame: *BcCallFrame, target: *Environment, name: []const u8, value: Value, configurable: bool, declare_only: bool) void {
    if (target.parent != null) return;
    // ES module top-level declarations live in the Module Environment Record
    // and must NOT become own-properties of the global object (spec §16.2.1.6).
    if (frame.func.is_module) return;
    if (isReservedRuntimeGlobal(name)) return;
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

/// CreateGlobalFunctionBinding (§10.1.1.4.18) mirror for a top-level function
/// declaration. Unlike the `var` mirror, when a same-named own property already
/// exists it *redefines* the descriptor — to { writable, enumerable, configurable:D }
/// — whenever the existing property is configurable, and otherwise just updates
/// the value. This is what makes `Object.defineProperty(this,'f',{configurable:true,
/// writable:false}); eval('function f(){}')` leave `f` writable & enumerable.
fn mirrorGlobalFunctionBinding(frame: *BcCallFrame, target: *Environment, name: []const u8, value: Value, configurable: bool) void {
    if (target.parent != null) return;
    if (frame.func.is_module) return;
    if (isReservedRuntimeGlobal(name)) return;
    const gt = frame.env.lookup("globalThis") catch return;
    if (gt.bits == 0 or gt.unbox() != .object) return;
    const obj = gt.toPtr().object;
    if (obj.ownAttr(name)) |existing| {
        // Existing non-configurable property: keep its descriptor, set value only.
        if (!existing.configurable) {
            obj.set(name, value) catch {};
            return;
        }
    }
    // No property, or an existing configurable one: (re)define fully.
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
    // getBindingByName can run a with-object @@unscopables getter, which may
    // throw; route it through the try/catch handler search.
    return getBindingByName(self, frame, rdst, name) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error resolving binding")) |oc| return oc;
        return null;
    };
}

/// Object Environment Record GetBindingValue(N) for a `with`-object (§9.1.1.2.6):
/// HasProperty(bindings, N) THEN Get(bindings, N). HasBinding already resolved
/// `wobj` (so the property is normally present), but the spec still performs the
/// HasProperty — observable as a `has` trap on a Proxy environment — before the
/// Get. Both run user code and can realloc `self.frames`.
fn withGetBindingValue(self: *BcVm, wobj: Value, name: []const u8) !Value {
    const key = try val_mod.makeString(self.arena, name);
    _ = try self.hasProperty(wobj, key);
    return self.getProp(wobj, name);
}

/// GetValue for an identifier Reference resolved by name (GET_GLOBAL, and the
/// fallback for a GET_REF whose token designates nothing reusable).
fn getBindingByName(self: *BcVm, frame_in: *BcCallFrame, rdst: u8, name: []const u8) !?RunOutcome {
    // `ownWith`/`inheritedWith` run user code (a @@unscopables / HasProperty
    // getter or Proxy trap) that can realloc `self.frames`; re-fetch `frame`
    // after each so later `frame.env`/`frame.registers` accesses aren't dangling.
    var frame = frame_in;
    // `with` scopes (if any) shadow the lexical/global scope: an object whose
    // [[HasProperty]] is true provides the binding via [[Get]].
    if (frame.with_stack.items.len > 0) {
        if (try ownWith(self, frame, name)) |wobj| {
            // The [[Get]] runs a getter (re-entrant) → self.frames can realloc,
            // leaving `frame` dangling. Write through the re-fetched top frame.
            const v = try withGetBindingValue(self, wobj, name);
            self.frames.items[self.frames.items.len - 1].registers[rdst] = v;
            return null;
        }
        frame = &self.frames.items[self.frames.items.len - 1];
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
                const v = try withGetBindingValue(self, wobj, name);
                self.frames.items[self.frames.items.len - 1].registers[rdst] = v;
                return null;
            }
            frame = &self.frames.items[self.frames.items.len - 1];
            if (frame.inherited_env_floor != null) {
                if (frame.env.lookup(name)) |v| {
                    frame.registers[rdst] = v;
                    return null;
                } else |_| {}
            }
            if (self.realm.global_env.lookup(name)) |v| {
                frame.registers[rdst] = v;
            } else |_| if (try globalObjectGet(self, frame, name)) |v| {
                self.frames.items[self.frames.items.len - 1].registers[rdst] = v;
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
            if (self.realm.global_env.lookup(name)) |v| {
                frame.registers[rdst] = v;
            } else |_| if (try globalObjectGet(self, frame, name)) |v| {
                self.frames.items[self.frames.items.len - 1].registers[rdst] = v;
            } else {
                frame.registers[rdst] = try val_mod.makeUndefined(self.arena);
            }
        },
        error.OutOfMemory => return error.OutOfMemory,
    }
    return null;
}

/// CreateGlobalVarBinding step 5 gates the whole binding creation on
/// `HasOwnProperty(globalObject, N)` being false. When the global object already
/// carries the name, the global Environment Record keeps resolving it through
/// its object record, so declaring a shadowing declarative binding here would
/// reset an existing global to `undefined` (`Object.defineProperty(globalThis,
/// "f", {value: "x"}); eval("var f")` must still read `"x"`).
fn globalObjectHasOwn(frame: *BcCallFrame, name: []const u8) bool {
    const gt = frame.env.lookup("globalThis") catch return false;
    if (gt.bits == 0 or gt.unbox() != .object) return false;
    return gt.toPtr().object.hasOwn(name);
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
    const target = varTargetEnv(frame);
    const shadows_global = target.parent == null and !frame.func.is_module and
        !isReservedRuntimeGlobal(name) and
        !target.bindings.contains(name) and globalObjectHasOwn(frame, name);
    // EvalDeclarationInstantiation (§19.2.1.3) creates its top-level `var`/
    // function bindings by calling CreateMutableBinding(N, true) — the `true`
    // marks them deletable, so a later `delete N` inside the eval body (or a
    // closure that captured N) actually removes the binding. This applies to
    // eval whose VariableEnvironment is a *function* var scope; at global scope
    // the binding lives in the global Environment Record and its deletability is
    // carried by the mirrored global-object property (deleteName returns
    // `global_object_ref` there), so the record binding itself stays plain.
    // Script/function body vars are never deletable.
    if (!shadows_global) {
        if (frame.func.is_eval and target.parent != null)
            target.hoistVarDeletable(name, undef) catch return error.OutOfMemory
        else
            target.hoistVar(name, undef) catch return error.OutOfMemory;
    }
    // ES §9.1.1.4.17 CreateGlobalVarBinding: a top-level `var`/function name in
    // Script or eval code reserves an own property of the global object at
    // declaration-instantiation time, even when it is never assigned (`var x;`
    // still yields `globalThis.x === undefined`). Bindings introduced by eval
    // are deletable; Script-level ones are not.
    mirrorGlobalBindingOptsIn(frame, target, name, undef, frame.func.is_eval, true);
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

/// Push a fresh *variable* environment for a function body whose parameter list
/// has initializer expressions (§10.2.11): body `var`/function declarations bind
/// here, separate from the parameter environment, so parameter-scope closures
/// never observe body `var` bindings. Never popped — the frame is discarded on
/// return.
pub inline fn opPushVarEnv(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    frame.env = Environment.initVarScope(self.arena, frame.env) catch return error.OutOfMemory;
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
    // Snapshot the with-object slice up front: withHasBinding runs user code
    // (a @@unscopables / HasProperty getter or Proxy trap) that can realloc
    // `self.frames`, leaving `frame` dangling — dereferencing `frame.with_stack`
    // inside the loop would then read freed memory. The slice's backing buffer is
    // separately arena-allocated and is not touched while another frame runs, so
    // the copied slice stays valid across those calls.
    const items = frame.with_stack.items;
    var i = hi;
    while (i > lo) {
        i -= 1;
        const wobj = items[i];
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

// ------------------------------------------------- resolved references (§6.2.5)
//
// `x op= y`, `x = y` and `++x` must resolve the Reference for `x` ONCE, before
// the right-hand side runs, and write through *that* Reference — even if the
// binding it names has since moved or disappeared:
//
//     with (o) { x *= (delete o.x, 3) }   // still assigns o.x
//     x = (eval("var x"), 1)              // still assigns the OUTER x
//
// A name-based SET_GLOBAL re-resolves and gets a different answer. The
// RESOLVE_REF / GET_REF / PUT_REF trio carries the resolution across the RHS as
// a token held in an ordinary register:
//
//   * an object Value — the binding object of an object Environment Record
//     (a `with` scope), written through with [[Set]];
//   * a number ≥ 0 — how many hops up the declarative environment chain the
//     binding lives, assigned directly in that record;
//   * -1 — resolved nowhere reusable; PUT_REF falls back to the plain
//     name-based path (unresolvable references, the global object, and the
//     cross-realm/inherited-floor cases all land here, unchanged).
//
// The compiler only emits them for functions that contain a `with` or a direct
// `eval` (see `dynamic_scope` in compiler.zig), so the ordinary path — and the
// int JIT, which pattern-matches GET_GLOBAL/SET_GLOBAL — is untouched.
const REF_FALLBACK: f64 = -1;

/// Nth parent of `env`, or null if the chain is shorter than `depth`.
fn envAtDepth(env: *Environment, depth: usize) ?*Environment {
    var cur = env;
    var i: usize = 0;
    while (i < depth) : (i += 1) cur = cur.parent orelse return null;
    return cur;
}

/// Locate the binding for `name` and return it as a reference token. Mirrors the
/// resolution order of `opGetGlobal`/`opSetGlobal`; anything those two reach by
/// a path this cannot describe comes back as the fallback token.
fn resolveRefToken(self: *BcVm, frame_in: *BcCallFrame, name: []const u8) !Value {
    var frame = frame_in;
    if (frame.with_stack.items.len > 0) {
        if (try ownWith(self, frame, name)) |wobj| return wobj;
        // ownWith may have run a @@unscopables getter that reallocated frames.
        frame = &self.frames.items[self.frames.items.len - 1];
    }
    var depth: usize = 0;
    var cur: ?*Environment = frame.env;
    while (cur) |e| {
        if (frame.inherited_env_floor) |floor| if (e == floor) break;
        if (e.bindings.contains(name)) return val_mod.makeNumber(self.arena, @floatFromInt(depth));
        cur = e.parent;
        depth += 1;
    }
    if (try inheritedWith(self, frame, name)) |wobj| return wobj;
    return val_mod.makeNumber(self.arena, REF_FALLBACK);
}

pub inline fn opResolveRef(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rref = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    // resolveRefToken can run a with-object @@unscopables / HasProperty getter,
    // which may throw; route it through the try/catch handler search.
    const token = resolveRefToken(self, frame, name) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error resolving with binding")) |oc| return oc;
        return null;
    };
    // resolveRefToken can run a with-object [[HasProperty]] trap, which may have
    // reallocated self.frames — write through the re-fetched top frame.
    self.frames.items[self.frames.items.len - 1].registers[rref] = token;
    return null;
}

/// GET_REF: resolve the reference, record it in R[ref], and GetValue it into
/// R[dst]. The read goes through the token so the binding object's
/// [[HasProperty]] is not consulted a second time.
pub inline fn opGetRef(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rdst = code[frame.pc];
    frame.pc += 1;
    const rref = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    // resolveRefToken can run a with-object @@unscopables / HasProperty getter,
    // which may throw. Route that through the bytecode try/catch handler search
    // rather than letting the raw error.JsException bubble past every JS `try`.
    const token = resolveRefToken(self, frame, name) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error resolving with binding")) |oc| return oc;
        return null;
    };
    {
        const top = &self.frames.items[self.frames.items.len - 1];
        top.registers[rref] = token;
    }
    if (token.bits != 0 and token.unbox() == .object) {
        const v = self.getProp(token, name) catch |e| {
            if (e != error.JsException) return e;
            if (try self.raisePendingException("error in with getter")) |oc| return oc;
            return null;
        };
        self.frames.items[self.frames.items.len - 1].registers[rdst] = v;
        return null;
    }
    const depth = token.unbox().number;
    if (depth >= 0) {
        if (envAtDepth(frame.env, @intFromFloat(depth))) |env| {
            if (env.lookupUntil(name, env.parent)) |v| {
                frame.registers[rdst] = v;
                return null;
            } else |err| switch (err) {
                error.TemporalDeadZone => {
                    const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
                    const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
                    self.last_exception_value = exc_val;
                    const found = try self.throwException(exc_val);
                    if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                    return null;
                },
                else => {},
            }
        }
    }
    // Unresolvable through the token: replay the ordinary name-based read, which
    // owns the ReferenceError / global-object fallbacks.
    return getBindingByName(self, frame, rdst, name) catch |e| {
        if (e != error.JsException) return e;
        if (try self.raisePendingException("error resolving binding")) |oc| return oc;
        return null;
    };
}

pub inline fn opPutRef(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    const code = frame.func.chunk.code;
    const rref = code[frame.pc];
    frame.pc += 1;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const value = frame.registers[rsrc];
    const token = frame.registers[rref];

    // Object Environment Record: SetMutableBinding [[Set]]s the binding object
    // whether or not the property is still there (creating it when it is not);
    // in strict code a vanished binding is a ReferenceError instead.
    if (token.bits != 0 and token.unbox() == .object) {
        // SetMutableBinding(N,V,S) for an object env record (§9.1.1.2.5): a plain
        // HasProperty — observable as a `has` trap on a Proxy env, and distinct
        // from the unscopables-aware HasBinding the reference resolution already
        // ran — THEN [[Set]]. A binding that vanished after resolution is a
        // ReferenceError in strict code; otherwise the [[Set]] still runs.
        const key = try val_mod.makeString(self.arena, name);
        const still_exists = try self.hasProperty(token, key);
        if (frame.func.is_strict and !still_exists) {
            const msg = try std.fmt.allocPrint(self.arena, "{s} is not defined", .{name});
            const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
            return null;
        }
        const ok = try self.setPropR(token, name, value, token);
        // A failed [[Set]] on the binding object (e.g. a non-writable property)
        // is a TypeError in strict code, a silent no-op otherwise.
        if (!ok and frame.func.is_strict) {
            const msg = try std.fmt.allocPrint(self.arena, "Cannot assign to read only property '{s}'", .{name});
            const exc_val = try self.makeErrorObjectBc("TypeError", msg);
            self.last_exception_value = exc_val;
            const found = try self.throwException(exc_val);
            if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
        }
        return null;
    }
    if (token.bits != 0 and token.unbox() == .number) {
        const depth = token.unbox().number;
        if (depth >= 0) {
            if (envAtDepth(frame.env, @intFromFloat(depth))) |env| {
                if (env.assignUntil(name, value, env.parent)) |_| {
                    mirrorGlobalBinding(frame, name, value, true);
                    return null;
                } else |err| switch (err) {
                    error.TemporalDeadZone => {
                        const msg = try std.fmt.allocPrint(self.arena, "Cannot access '{s}' before initialization", .{name});
                        const exc_val = try self.makeErrorObjectBc("ReferenceError", msg);
                        self.last_exception_value = exc_val;
                        const found = try self.throwException(exc_val);
                        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                        return null;
                    },
                    error.ConstAssignment => {
                        const msg = try std.fmt.allocPrint(self.arena, "Assignment to constant variable.", .{});
                        const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                        self.last_exception_value = exc_val;
                        const found = try self.throwException(exc_val);
                        if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                        return null;
                    },
                    // The binding was deleted after it was resolved — the
                    // Reference is now unresolvable, so fall through.
                    else => {},
                }
            }
        }
    }
    return setBindingByName(self, frame, name, value);
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
    return setBindingByName(self, frame, name, value);
}

/// PutValue for an identifier Reference resolved by name (SET_GLOBAL, and the
/// fallback for a PUT_REF whose token no longer designates a binding).
/// Object Environment Record SetMutableBinding(N,V) for a `with`-object
/// (§9.1.1.2.5): HasProperty(bindings, N) — observable as a `has` trap on a Proxy
/// environment — THEN Set(bindings, N, V). Returns the [[Set]] result.
fn withSetBindingValue(self: *BcVm, wobj: Value, name: []const u8, value: Value) !bool {
    const key = try val_mod.makeString(self.arena, name);
    _ = try self.hasProperty(wobj, key);
    return self.setPropR(wobj, name, value, wobj);
}

fn setBindingByName(self: *BcVm, frame_in: *BcCallFrame, name: []const u8, value: Value) !?RunOutcome {
    var frame = frame_in;
    const cur_is_strict = frame.func.is_strict;
    // `with` scopes: assign through an object whose [[HasProperty]] is true.
    if (frame.with_stack.items.len > 0) {
        if (try ownWith(self, frame, name)) |wobj| {
            const ok = try withSetBindingValue(self, wobj, name, value);
            // A failed assignment (e.g. a non-writable property on the with
            // object) is a TypeError in strict code, a silent no-op otherwise.
            if (!ok and cur_is_strict) {
                const msg = try std.fmt.allocPrint(self.arena, "Cannot assign to read only property '{s}'", .{name});
                const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                self.last_exception_value = exc_val;
                const found = try self.throwException(exc_val);
                if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
            }
            return null;
        }
        // ownWith may have run a @@unscopables getter that reallocated frames.
        frame = &self.frames.items[self.frames.items.len - 1];
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
                const ok = try withSetBindingValue(self, wobj, name, value);
                if (!ok and cur_is_strict) {
                    const msg = try std.fmt.allocPrint(self.arena, "Cannot assign to read only property '{s}'", .{name});
                    const exc_val = try self.makeErrorObjectBc("TypeError", msg);
                    self.last_exception_value = exc_val;
                    const found = try self.throwException(exc_val);
                    if (!found) return RunOutcome{ .exception_value = .{ .msg = msg, .value = exc_val } };
                }
                return null;
            }
            frame = &self.frames.items[self.frames.items.len - 1];
            if (frame.inherited_env_floor != null) {
                if (frame.env.assign(name, value)) |_| {
                    mirrorGlobalBinding(frame, name, value, true);
                    return null;
                } else |_| {}
            }
            if (cur_is_strict) {
                // Before concluding this is unresolvable: a binding that lives on the
                // real global object (e.g. a sloppy-mode implicit global created
                // elsewhere, or a realm-level global binding not reachable through
                // this frame's own env chain) is NOT undeclared — assignment to an
                // *existing* global is legal in strict mode; only a truly
                // unresolvable reference throws (mirrors the GET_GLOBAL fallback
                // in `getBindingByName` below).
                if (self.realm.global_env.assign(name, value)) |_| {
                    return null;
                } else |_| {}
                const wrote_existing = blk: {
                    const gt = frame.env.lookup("globalThis") catch break :blk false;
                    if (gt.bits == 0 or gt.unbox() != .object) break :blk false;
                    const obj = gt.toPtr().object;
                    if (!obj.hasOwn(name)) break :blk false;
                    obj.set(name, value) catch break :blk false;
                    break :blk true;
                };
                if (wrote_existing) return null;
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
    // A top-level `let`/`const`/`class` is deliberately NOT mirrored — see
    // Environment.isGlobalVarBinding.
    if (frame.env.isGlobalVarBinding(name, frame.inherited_env_floor))
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
    // Try assign first (update existing binding), else define. A var/function
    // declaration in non-strict eval code belongs to the calling
    // VariableEnvironment, not to the eval's own declarative scope.
    frame.env.assign(name, value) catch {
        varTargetEnv(frame).define(name, value) catch return error.OutOfMemory;
    };
    // Top-level `var`/function declarations are also own properties of the
    // global object (observable as `globalThis.name`). Script-level ones are
    // non-configurable (DontDelete) — `delete globalThis.x` returns false —
    // while eval-introduced ones are deletable (EvalDeclarationInstantiation
    // passes varEnv.CreateGlobal{Var,Function}Binding a `true` deletable flag).
    mirrorGlobalBinding(frame, name, value, frame.func.is_eval);
    return null;
}

/// DEFINE_GLOBAL_FN: a top-level function declaration. Identical binding
/// resolution to DEFINE_GLOBAL, but the global-object mirror uses
/// CreateGlobalFunctionBinding semantics (redefine an existing configurable
/// property's descriptor to writable+enumerable) rather than leaving it intact.
pub inline fn opDefineGlobalFn(self: *BcVm, frame: *BcCallFrame) !?RunOutcome {
    _ = self;
    const code = frame.func.chunk.code;
    const lo = code[frame.pc];
    frame.pc += 1;
    const hi = code[frame.pc];
    frame.pc += 1;
    const kidx: u16 = @as(u16, lo) | (@as(u16, hi) << 8);
    const rsrc = code[frame.pc];
    frame.pc += 1;
    const name = frame.func.chunk.constants[kidx].toPtr().string;
    const value = frame.registers[rsrc];
    frame.env.assign(name, value) catch {
        varTargetEnv(frame).define(name, value) catch return error.OutOfMemory;
    };
    mirrorGlobalFunctionBinding(frame, varTargetEnv(frame), name, value, frame.func.is_eval);
    return null;
}

/// As `mirrorGlobalBinding`, for a caller that already resolved which
/// environment record the binding was made in.
fn mirrorGlobalBindingIn(frame: *BcCallFrame, target: *Environment, name: []const u8, value: Value, configurable: bool) void {
    if (target.parent != null) return;
    if (frame.func.is_module) return;
    if (isReservedRuntimeGlobal(name)) return;
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
    // A missing declarative binding is not a failure at global scope: when the
    // name is already an own property of the global object, CreateGlobalVarBinding
    // deliberately created no binding (see opHoistVar), and this
    // SetMutableBinding routes through the global Environment Record's object
    // record instead — so still mirror the value out.
    target.assign(name, value) catch {};
    mirrorGlobalBindingIn(frame, target, name, value, false);
    return null;
}

/// `delete <identifier>` (ES `delete` on an environment Reference). Resolves the
/// name over the scope chain WITHOUT evaluating its value, and stores the boolean
/// result in Rdst. See the DELETE_NAME opcode doc for the full precedence.
pub inline fn opDeleteName(self: *BcVm, frame_in: *BcCallFrame) !?RunOutcome {
    var frame = frame_in;
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
        // ownWith may have run a @@unscopables getter that reallocated frames.
        frame = &self.frames.items[frame_idx];
    }

    // 2) Environment record binding. A local/lexical declarative binding is
    //    non-deletable (false). A global object-record binding (var/function/
    //    implicit/builtin) defers to the global object's [[Delete]] below.
    const classify = frame.env.deleteName(name);
    if (classify == .not_deletable or classify == .deleted) {
        frame.registers[rdst] = try val_mod.makeBool(self.arena, classify == .deleted);
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
        frame = &self.frames.items[frame_idx];
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
