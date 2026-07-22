// SPDX-License-Identifier: Apache-2.0
//! Lexical scope chain (Environment). define/lookup/assign bindings.
//! Arena-allocated; no deallocation needed per-binding.
const std = @import("std");
const Value = @import("../value/value.zig").Value;

pub const EnvError = error{
    OutOfMemory,
    NotDefined,
    TemporalDeadZone,
    ConstAssignment,
};

pub const BindingKind = enum {
    var_,
    let,
    const_,
};

pub const Binding = struct {
    value: Value,
    kind: BindingKind,
    initialized: bool,
    /// A CreateImmutableBinding(N, false) record: assignment is *silently
    /// ignored* rather than an error. The only such binding in the language is
    /// a sloppy-mode named function expression's self-name (§15.2.5), so
    /// `(function f(){ f = 1; return f })()` returns the function. The strict
    /// form (throwOnError = true) is modelled as `kind == .const_` instead.
    immutable: bool = false,
    /// EvalDeclarationInstantiation creates its `var`/function bindings with the
    /// deletable flag set (§19.2.1.3 passes `true` to CreateMutableBinding), so
    /// `eval("var x"); delete x` actually removes them — unlike every binding a
    /// declaration in the surrounding code makes.
    deletable: bool = false,
};

/// Result of `Environment.deleteName` (the `delete identifier` operation over the
/// scope chain). A local declarative binding is never deletable; a binding in the
/// global environment record's *object* part (var/function/implicit/builtin) defers
/// to the global object's [[Delete]] (configurability); a lexical global binding
/// (top-level let/const/class) is non-deletable; `not_found` means the caller
/// consults the global object directly (else the reference is unresolvable → true).
pub const DeleteNameResult = enum { not_found, not_deletable, global_object_ref, deleted };

/// A single lexical environment frame. Linked to parent.
pub const Environment = struct {
    parent: ?*Environment,
    bindings: std.StringHashMapUnmanaged(Binding),
    arena: std.mem.Allocator,
    /// True for a *variable* environment — the record a `var`/function
    /// declaration binds into. Function call scopes (and the root/global scope,
    /// which qualifies by having no parent) are variable environments; block
    /// scopes pushed by ENTER_SCOPE are not. Direct `eval` runs in a fresh
    /// declarative scope but hoists its vars to `varScope()`, i.e. the
    /// enclosing function or global scope, per EvalDeclarationInstantiation.
    is_var_scope: bool = false,

    pub fn init(arena: std.mem.Allocator, parent: ?*Environment) !*Environment {
        const env = try arena.create(Environment);
        env.* = Environment{
            .parent = parent,
            .bindings = .{},
            .arena = arena,
        };
        return env;
    }

    /// A function-call (variable) environment: `var` declarations made anywhere
    /// inside it bind here rather than escaping to an enclosing scope.
    pub fn initVarScope(arena: std.mem.Allocator, parent: ?*Environment) !*Environment {
        const env = try Environment.init(arena, parent);
        env.is_var_scope = true;
        return env;
    }

    /// The nearest enclosing variable environment (this one, if it qualifies).
    /// The root of a chain is always a variable environment.
    pub fn varScope(self: *Environment) *Environment {
        var cur = self;
        while (!cur.is_var_scope) cur = cur.parent orelse return cur;
        return cur;
    }

    /// Hoist a `var`/function-declaration binding into THIS frame: define it as
    /// `value` (usually undefined) only if this frame has no own binding for the
    /// name yet. Never walks the parent chain and never clobbers an existing
    /// binding (e.g. a parameter, or an already-hoisted name). This gives every
    /// `var` an `undefined` value at scope entry without overwriting params.
    pub fn hoistVar(self: *Environment, name: []const u8, value: Value) !void {
        if (self.bindings.contains(name)) return;
        try self.define(name, value);
    }

    /// `hoistVar` for eval code: the new binding is deletable (see `Binding.deletable`).
    pub fn hoistVarDeletable(self: *Environment, name: []const u8, value: Value) !void {
        if (self.bindings.contains(name)) return;
        try self.bindings.put(self.arena, name, .{
            .value = value,
            .kind = .var_,
            .initialized = true,
            .deletable = true,
        });
    }

    /// Define a var-style binding in THIS frame.
    pub fn define(self: *Environment, name: []const u8, value: Value) !void {
        try self.bindings.put(self.arena, name, .{
            .value = value,
            .kind = .var_,
            .initialized = true,
        });
    }

    /// Define a lexical binding in THIS frame. If `initialized` is false, the binding
    /// is in TDZ and any lookup/assignment should throw until initialized.
    pub fn defineLexical(self: *Environment, name: []const u8, kind: BindingKind, initialized: bool, value: Value) !void {
        try self.bindings.put(self.arena, name, .{
            .value = value,
            .kind = kind,
            .initialized = initialized,
        });
    }

    /// CreateImmutableBinding + InitializeBinding in THIS frame. `strict` picks
    /// the throwOnError form: a strict named function expression's self-name
    /// rejects assignment with a TypeError, the sloppy one ignores it.
    pub fn defineImmutable(self: *Environment, name: []const u8, value: Value, strict: bool) !void {
        try self.bindings.put(self.arena, name, .{
            .value = value,
            .kind = if (strict) .const_ else .var_,
            .initialized = true,
            .immutable = !strict,
        });
    }

    /// Upgrade a binding to const_ so subsequent assignments throw TypeError.
    pub fn upgradeToConst(self: *Environment, name: []const u8) void {
        if (self.bindings.getPtr(name)) |b| { b.kind = .const_; return; }
        if (self.parent) |p| p.upgradeToConst(name);
    }

    /// Initialize an existing lexical binding in this frame or any parent frame.
    pub fn initialize(self: *Environment, name: []const u8, value: Value) EnvError!void {
        if (self.bindings.getPtr(name)) |b| {
            b.value = value;
            b.initialized = true;
            return;
        }
        if (self.parent) |p| return p.initialize(name, value);
        return EnvError.NotDefined;
    }

    /// True if THIS frame has an own lexical (`let`/`const`) binding for `name`.
    /// Used by direct `eval` to detect a `var` declaration that conflicts with a
    /// lexical binding in the surrounding scope (EvalDeclarationInstantiation).
    pub fn hasOwnLexical(self: *Environment, name: []const u8) bool {
        if (self.bindings.get(name)) |b| return b.kind == .let or b.kind == .const_;
        return false;
    }

    /// Look up a binding in this frame or any parent.
    pub fn lookup(self: *Environment, name: []const u8) EnvError!Value {
        if (self.bindings.get(name)) |b| {
            if (!b.initialized) return EnvError.TemporalDeadZone;
            return b.value;
        }
        if (self.parent) |p| return p.lookup(name);
        return EnvError.NotDefined;
    }

    /// `lookup`, but stopping before `stop` (exclusive). Used to search only the
    /// bindings a call frame introduced — its parameters, vars and block scopes —
    /// without reaching its definition environment, so that an object environment
    /// record (`with` scope) inherited from the definition site can be consulted
    /// in between. A null `stop` degenerates to `lookup`.
    pub fn lookupUntil(self: *Environment, name: []const u8, stop: ?*Environment) EnvError!Value {
        if (stop) |s| if (self == s) return EnvError.NotDefined;
        if (self.bindings.get(name)) |b| {
            if (!b.initialized) return EnvError.TemporalDeadZone;
            return b.value;
        }
        if (self.parent) |p| return p.lookupUntil(name, stop);
        return EnvError.NotDefined;
    }

    /// `assign`, but stopping before `stop` (exclusive). See `lookupUntil`.
    pub fn assignUntil(self: *Environment, name: []const u8, value: Value, stop: ?*Environment) EnvError!void {
        if (stop) |s| if (self == s) return EnvError.NotDefined;
        if (self.bindings.getPtr(name)) |b| {
            if (!b.initialized) return EnvError.TemporalDeadZone;
            if (b.immutable) return; // silently ignored, see Binding.immutable
            if (b.kind == .const_) return EnvError.ConstAssignment;
            b.value = value;
            return;
        }
        if (self.parent) |p| return p.assignUntil(name, value, stop);
        return EnvError.NotDefined;
    }

    /// True when `name` resolves — searching up from `self`, stopping before
    /// `stop` — to a `var`-kind binding in the *global* environment record.
    /// Those are the only bindings the global object mirrors as own properties:
    /// a top-level `let`/`const`/`class` lives purely in the global declarative
    /// record, and mirroring it would leave `globalThis.x` a second copy that a
    /// `with (globalThis)` scope writes to while the real binding stays behind.
    pub fn isGlobalVarBinding(self: *Environment, name: []const u8, stop: ?*Environment) bool {
        var cur: ?*Environment = self;
        while (cur) |e| {
            if (stop) |s| if (e == s) return false;
            if (e.bindings.getPtr(name)) |b| return e.parent == null and b.kind == .var_;
            cur = e.parent;
        }
        return false;
    }

    /// Assign an existing binding (walk up the chain).
    pub fn assign(self: *Environment, name: []const u8, value: Value) EnvError!void {
        if (self.bindings.getPtr(name)) |b| {
            if (!b.initialized) return EnvError.TemporalDeadZone;
            if (b.immutable) return; // silently ignored, see Binding.immutable
            if (b.kind == .const_) return EnvError.ConstAssignment;
            b.value = value;
            return;
        }
        if (self.parent) |p| return p.assign(name, value);
        return EnvError.NotDefined;
    }

    /// Mirror a `globalThis.name = value` write into an existing top-level `var`
    /// binding of the same name, keeping the global environment record and the
    /// global object in sync. No-op unless an initialized `var` binding exists
    /// (lexical/const globals are not aliased to global-object properties).
    pub fn mirrorGlobalVar(self: *Environment, name: []const u8, value: Value) void {
        if (self.bindings.getPtr(name)) |b| {
            if (b.kind == .var_ and b.initialized) b.value = value;
        }
    }

    /// `delete identifier` classification over the scope chain (ES `delete` on an
    /// environment Reference), WITHOUT mutating anything. Walks to the first frame
    /// binding `name`:
    ///   - a binding in a *local* frame (parent != null) → `.not_deletable`
    ///     (function/block declarative bindings can't be deleted);
    ///   - a `let`/`const` binding in the *global* frame → `.not_deletable`
    ///     (global lexical declarations live only in the declarative record);
    ///   - a `var`-kind binding in the global frame (var/function/implicit/builtin)
    ///     → `.global_object_ref` (defer to the global object's [[Delete]]);
    ///   - no binding → `.not_found`.
    pub fn deleteName(self: *Environment, name: []const u8) DeleteNameResult {
        if (self.bindings.getPtr(name)) |b| {
            if (b.deletable) {
                _ = self.bindings.remove(name);
                return .deleted;
            }
            if (self.parent != null) return .not_deletable; // local declarative binding
            if (b.kind == .let or b.kind == .const_) return .not_deletable; // global lexical
            return .global_object_ref; // global object-record binding
        }
        if (self.parent) |p| return p.deleteName(name);
        return .not_found;
    }

    /// Remove `name` from the global (root) environment frame. Used after a
    /// `delete <identifier>` successfully removes the mirrored global-object
    /// property, keeping the environment record and the global object in sync.
    pub fn removeGlobalBinding(self: *Environment, name: []const u8) void {
        if (self.parent) |p| return p.removeGlobalBinding(name);
        _ = self.bindings.remove(name);
    }

    /// Define or create in the global frame (walk to root).
    pub fn defineGlobal(self: *Environment, name: []const u8, value: Value) !void {
        if (self.parent == null) {
            try self.define(name, value);
            return;
        }
        try self.parent.?.defineGlobal(name, value);
    }
};

// ------------------------------------------------------------------- tests ---

test "Environment: define and lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const v = try val.makeNumber(arena.allocator(), 42);
    const env = try Environment.init(arena.allocator(), null);
    try env.define("x", v);
    const got = try env.lookup("x");
    try std.testing.expectEqual(@as(f64, 42), got.toF64());
}

test "Environment: lexical TDZ and initialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const env = try Environment.init(arena.allocator(), null);
    const undef = try val.makeUndefined(arena.allocator());
    try env.defineLexical("x", .let, false, undef);
    try std.testing.expectError(EnvError.TemporalDeadZone, env.lookup("x"));
    const one = try val.makeNumber(arena.allocator(), 1);
    try env.initialize("x", one);
    const got = try env.lookup("x");
    try std.testing.expectEqual(@as(f64, 1), got.toF64());
}

test "Environment: const assignment rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const env = try Environment.init(arena.allocator(), null);
    const one = try val.makeNumber(arena.allocator(), 1);
    try env.defineLexical("c", .const_, true, one);
    const two = try val.makeNumber(arena.allocator(), 2);
    try std.testing.expectError(EnvError.ConstAssignment, env.assign("c", two));
}

test "Environment: parent chain lookup" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const parent = try Environment.init(arena.allocator(), null);
    const v = try val.makeNumber(arena.allocator(), 10);
    try parent.define("y", v);
    const child = try Environment.init(arena.allocator(), parent);
    const got = try child.lookup("y");
    try std.testing.expectEqual(@as(f64, 10), got.toF64());
}

test "Environment: assign walks chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const val = @import("../value/value.zig");
    const parent = try Environment.init(arena.allocator(), null);
    const v1 = try val.makeNumber(arena.allocator(), 1);
    try parent.define("z", v1);
    const child = try Environment.init(arena.allocator(), parent);
    const v2 = try val.makeNumber(arena.allocator(), 2);
    try child.assign("z", v2);
    const got = try parent.lookup("z");
    try std.testing.expectEqual(@as(f64, 2), got.toF64());
}
