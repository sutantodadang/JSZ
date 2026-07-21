// SPDX-License-Identifier: Apache-2.0
//! BcFunction and BcClosure: bytecode function representation for Phase 2.
const std = @import("std");
const Chunk = @import("./chunk.zig").Chunk;
const ic_mod = @import("../vm/ic.zig");

/// A compiled bytecode function. Owned by the compile arena.
pub const BcFunction = struct {
    name: ?[]const u8,
    /// Function.prototype.toString: retained exact source text for this
    /// function (see ast.FuncExpr.source_text / ast.FuncDecl.source_text).
    /// Null → native fallback format is used instead.
    source_text: ?[]const u8 = null,
    /// Named function EXPRESSION self-name: bound (immutably, per spec) inside
    /// the function's own scope so the body can refer to itself. Null for
    /// function DECLARATIONS — their name lives in the enclosing scope and is a
    /// normal mutable binding, so `function f(){ f = 2 }` reassigns the outer
    /// binding rather than shadowing it.
    nfe_name: ?[]const u8 = null,
    arity: u16,
    chunk: Chunk,
    num_regs: u16,
    /// Nested function literals referenced by NEW_CLOSURE funcIdx.
    child_functions: []*BcFunction,
    /// Parameter names for binding into env on call.
    param_names: [][]const u8,
    /// Rest parameter name (`function f(...rest)`), bound at call entry to an
    /// Array of the arguments past `param_names.len`. Null if none.
    rest_param: ?[]const u8 = null,
    /// Phase 4d: whether this function was compiled in strict mode.
    is_strict: bool = false,
    /// M14: body references `arguments` and is not an arrow → the VM materializes
    /// an `arguments` array-like object in the call env at every invocation site.
    uses_arguments: bool = false,
    /// M14: this is an arrow whose body (transitively through nested arrows)
    /// references `arguments`; the enclosing non-arrow function must therefore
    /// materialize one. Propagated up at compile time, not used by the VM.
    needs_parent_arguments: bool = false,
    /// W2: whether this is a generator function (`function*`). When called it
    /// produces a generator object instead of running the body.
    is_generator: bool = false,
    /// True when the (async)generator body contains a PARAMS_DONE marker (it has
    /// a destructuring-param prelude). The build driver runs the body up to the
    /// marker eagerly at call time so parameter errors propagate to the caller.
    has_param_init: bool = false,
    /// W2-async: whether this is an async function (`async function`). When
    /// called it runs as a reaction-driven coroutine and returns a Promise;
    /// each `await` suspends via a YIELD opcode.
    is_async: bool = false,
    /// Whether this function literal is an arrow. Arrows have no own `this`
    /// binding: the VM uses the `this` captured into the closure at NEW_CLOSURE
    /// time instead of any caller-provided value.
    is_arrow: bool = false,
    /// Whether this is a concise method (object/class method shorthand, getter,
    /// or setter). Concise methods are not constructors: a non-generator method
    /// has no own `prototype` property (spec MethodDefinitionEvaluation).
    is_method: bool = false,
    /// M16: this top-level function compiles ES-module code. Used so the VM binds
    /// the module's top-level `this` to undefined (a Script binds it to the global
    /// object). Only meaningful on a program/module top-level function.
    is_module: bool = false,
    /// Eval code: invoked with the calling/global VariableEnvironment directly
    /// (no fresh child env), so top-level `var`/function declarations hoist into
    /// that environment — and, at global scope, become global-object properties.
    is_eval: bool = false,
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
    /// Arrow functions capture the `this` of their definition site (they have no
    /// own `this` binding). Set at NEW_CLOSURE time when `func.is_arrow`; the call
    /// dispatch uses it for the frame's `this` instead of any caller-provided
    /// value (so `arrow.call(x)` / `[].map(()=>this, x)` keep the lexical this).
    /// `bits == 0` (the empty Value) when not an arrow / nothing captured.
    captured_this: @import("../value/value.zig").Value = .{},
    /// W2 unification: lazily-created backing object holding the function's own
    /// properties (incl. its `prototype` object, materialized on first access).
    /// Makes bc functions first-class objects so `C.prototype.m = ...`, `new C()`,
    /// and class desugaring work. `?*JsObject` stored opaque to avoid an import
    /// cycle (function.zig must not depend on object.zig).
    obj: ?*anyopaque = null,
    /// Cross-realm: which Realm created this closure (opaque *Realm, to avoid a
    /// circular import with runtime/realm.zig). Null = primary realm / untagged.
    /// Read by GetFunctionRealm for GetPrototypeFromConstructor's realm fallback.
    realm: ?*anyopaque = null,
    /// Object Environment Records (`with` scopes, outermost first) that enclosed
    /// this function's definition site. A function declared inside `with (o)`
    /// keeps resolving free names through `o` when it is called later, from
    /// anywhere — the with-object is part of its scope chain, not of the frame
    /// that happened to run the `with`. Seeded into the callee frame's
    /// `with_stack` below its own entries; empty for the common case.
    with_scopes: []const @import("../value/value.zig").Value = &.{},
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
