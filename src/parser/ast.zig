// SPDX-License-Identifier: Apache-2.0
//! ES5 AST nodes. Arena-allocated tagged unions. Phase 1.
const std = @import("std");

// ---------------------------------------------------------------- operators ---

pub const BinaryOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    exp,
    bit_and,
    bit_or,
    bit_xor,
    lshift,
    rshift,
    urshift,
    lt,
    lte,
    gt,
    gte,
    instanceof,
    in,
    eq,
    neq,
    strict_eq,
    strict_neq,
};

pub const AssignOp = enum {
    assign,
    add,
    sub,
    mul,
    div,
    mod,
    exp,
    bit_and,
    bit_or,
    bit_xor,
    lshift,
    rshift,
    urshift,
    // ES2021 logical assignment (short-circuiting).
    logical_and,
    logical_or,
    logical_nullish,
};

pub const UnaryOp = enum {
    neg,
    pos,
    not,
    bit_not,
    typeof_,
    void_,
    delete_,
    pre_inc,
    pre_dec,
};

pub const LogicalOp = enum { and_, or_, nullish };

pub const UpdateOp = enum { inc, dec };

// ---------------------------------------------------------------- node enum ---

pub const NodeKind = enum {
    // Expressions
    number_literal,
    bigint_literal,
    string_literal,
    bool_literal,
    null_literal,
    undefined_literal,
    identifier,
    this_expr,
    unary_expr,
    binary_expr,
    logical_expr,
    assignment_expr,
    update_expr,
    conditional_expr,
    sequence_expr,
    spread_expr,
    yield_expr,
    call_expr,
    new_expr,
    member_expr,
    /// ES2020 optional chain root — wraps the outermost member/call of a chain
    /// that contains at least one `?.` link. Establishes the short-circuit
    /// boundary: if any optional link sees a nullish base the whole chain
    /// evaluates to `undefined`.
    optional_chain,
    function_expr,
    // Phase 3a: object and array literals
    object_literal,
    array_literal,
    /// Elision hole in an array literal (`[1,,3]`). Distinct from
    /// `undefined_literal`: it produces a genuinely absent index (a dense hole),
    /// so `1 in [1,,3]` is false, whereas `[1,undefined,3]` has index 1 present.
    array_hole,
    // Statements
    program,
    expr_stmt,
    block_stmt,
    var_decl,
    function_decl,
    if_stmt,
    while_stmt,
    do_while_stmt,
    with_stmt,
    for_stmt,
    return_stmt,
    break_stmt,
    continue_stmt,
    empty_stmt,
    debugger_stmt,
    // Marker between a generator's formal-parameter initialization (destructuring
    // prelude + defaults) and its body. The generator build driver runs the body
    // up to this point eagerly at call time, so param errors propagate to the
    // caller (spec FunctionDeclarationInstantiation runs before GeneratorStart).
    params_done,
    // Phase 4a: exceptions
    throw_stmt,
    try_stmt,
    // Phase 4c: regex literal
    regex_literal,
    // Phase 4d: for-in, switch, labels
    for_in_stmt,
    switch_stmt,
    labeled_stmt,
};

// ---------------------------------------------------------------- node type ---

pub const Node = struct {
    kind: NodeKind,
    start: u32,
    end: u32,
    data: Data,
    /// True if this expression was wrapped in parentheses (affects `**` left-operand rule).
    paren: bool = false,
};

pub const Data = union(NodeKind) {
    number_literal: f64,
    bigint_literal: []const u8,
    string_literal: []const u8,
    bool_literal: bool,
    null_literal: void,
    undefined_literal: void,
    identifier: []const u8,
    this_expr: void,
    unary_expr: UnaryExpr,
    binary_expr: BinaryExpr,
    logical_expr: LogicalExpr,
    assignment_expr: AssignExpr,
    update_expr: UpdateExpr,
    conditional_expr: CondExpr,
    sequence_expr: SeqExpr,
    spread_expr: *Node,
    yield_expr: ?*Node,
    call_expr: CallExpr,
    new_expr: NewExpr,
    member_expr: MemberExpr,
    optional_chain: *Node,
    function_expr: FuncExpr,
    object_literal: ObjectLiteral,
    array_literal: ArrayLiteral,
    array_hole: void,
    program: Program,
    expr_stmt: *Node,
    block_stmt: BlockStmt,
    var_decl: VarDecl,
    function_decl: FuncDecl,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
    do_while_stmt: DoWhileStmt,
    with_stmt: WithStmt,
    for_stmt: ForStmt,
    return_stmt: ?*Node,
    break_stmt: ?[]const u8,
    continue_stmt: ?[]const u8,
    empty_stmt: void,
    debugger_stmt: void,
    params_done: void,
    // Phase 4a
    throw_stmt: *Node,
    try_stmt: TryStmt,
    // Phase 4c
    regex_literal: RegexLiteral,
    // Phase 4d
    for_in_stmt: ForInStmt,
    switch_stmt: SwitchStmt,
    labeled_stmt: LabeledStmt,
};

// ---------------------------------------------------------------- payloads ---

pub const UnaryExpr = struct {
    op: UnaryOp,
    operand: *Node,
};

pub const BinaryExpr = struct {
    op: BinaryOp,
    left: *Node,
    right: *Node,
};

pub const LogicalExpr = struct {
    op: LogicalOp,
    left: *Node,
    right: *Node,
};

pub const AssignExpr = struct {
    op: AssignOp,
    target: *Node,
    value: *Node,
};

pub const UpdateExpr = struct {
    op: UpdateOp,
    operand: *Node,
    prefix: bool,
};

pub const CondExpr = struct {
    test_: *Node,
    consequent: *Node,
    alternate: *Node,
};

pub const SeqExpr = struct {
    exprs: []*Node,
};

pub const CallExpr = struct {
    callee: *Node,
    args: []*Node,
    /// ES2020 optional call `f?.(args)`.
    optional: bool = false,
};

pub const NewExpr = struct {
    callee: *Node,
    args: []*Node,
};

pub const MemberExpr = struct {
    object: *Node,
    property: *Node,
    computed: bool,
    /// ES2020 optional member `obj?.prop` / `obj?.[expr]`.
    optional: bool = false,
    /// Set only by the class desugaring on the assignment targets that *install*
    /// a private element (field initializer, private method/accessor). Such a
    /// write is PrivateFieldAdd / PrivateMethodOrAccessorAdd and creates the
    /// element; every ordinary `obj.#x = v` is PrivateSet and requires one to
    /// already exist. Compiles to DEFINE_PRIVATE instead of SET_PROP.
    private_define: bool = false,
    /// Narrows `private_define` to PrivateMethodOrAccessorAdd: the installed
    /// element is a private method, which is non-writable, so a later
    /// `obj.#m = v` is a TypeError instead of a field update.
    private_method: bool = false,
};

pub const FuncExpr = struct {
    name: ?[]const u8,
    params: [][]const u8,
    param_defaults: []?*Node = &[_]?*Node{},
    /// See ParamParse.expected_argc — null means "params.len".
    expected_argc: ?u16 = null,
    rest_param: ?[]const u8 = null,
    body: []*Node,
    is_arrow: bool = false,
    is_generator: bool = false,
    is_async: bool = false,
    is_strict: bool = false,
    requires_super: bool = false,
    /// True for object/class method shorthand. A method's name (for the `.name`
    /// property) is NOT bound inside its own body — unlike a named function
    /// expression — so this suppresses the inner self-binding at compile time.
    is_method: bool = false,
    /// Function.prototype.toString: exact original source text for this
    /// function literal (params+body, or the whole arrow), sliced from the
    /// parser's source buffer. Null when no meaningful span was captured
    /// (synthetic/desugared function nodes) — callers fall back to the
    /// native "[native code]" format in that case.
    source_text: ?[]const u8 = null,
};

/// Phase 3a: a single property in an object literal.
pub const PropKind = enum { init, get, set };

pub const ObjectProp = struct {
    /// Property key (always stored as a string, even for numeric keys).
    /// Ignored when `computed_key` is set.
    key: []const u8,
    value: *Node,
    kind: PropKind = .init,
    /// ES6 computed key `{ [expr]: value }`: the key is evaluated at runtime
    /// (may yield a symbol). `null` for ordinary static keys.
    computed_key: ?*Node = null,
    /// IsAnonymousFunctionDefinition(value) — the value is a function/class/arrow
    /// literal with no binding name, so NamedEvaluation applies. Only meaningful
    /// together with `computed_key`, where the name is not known until runtime.
    anon_value: bool = false,
};

/// Phase 3a: object literal { key: value, ... }
pub const ObjectLiteral = struct {
    properties: []ObjectProp,
};

/// Phase 3a: array literal [ expr, expr, ... ]
pub const ArrayLiteral = struct {
    elements: []*Node,
};

/// Phase 4c: regex literal /pattern/flags
pub const RegexLiteral = struct {
    pattern: []const u8,
    flags: []const u8,
};

pub const Program = struct {
    body: []*Node,
    is_generator: bool = false,
    is_strict: bool = false,
    /// True when this program is ES-module code (`parseModule`). Module code is
    /// always strict (§11.2.2); kept distinct from `is_strict` so the compiler
    /// can apply module-only semantics later without inferring it from strict.
    is_module: bool = false,
    /// M16 TLA: the module has top-level await, so its top-level body must be
    /// compiled as async (and driven as a coroutine) for real await suspension.
    has_tla: bool = false,
};

pub const BlockStmt = struct {
    body: []*Node,
    /// True for a real `{ ... }` block (its own lexical scope). False for a
    /// synthetic statement-sequence container (e.g. the class-declaration
    /// desugaring, multi-declarator lowering) whose `let`/`const` bindings must
    /// belong to the *enclosing* scope, not a fresh block scope.
    lexical_scope: bool = true,
};

pub const VarKind = enum {
    var_,
    let,
    const_,
};

/// Explicit resource management: marks a `let`-lowered declaration that came from
/// a `using` / `await using` declaration so the scope-wrapping desugar can find
/// the resources to register on the disposable-resource stack.
pub const UsingKind = enum {
    none,
    using_,
    await_using_,
};

pub const VarDecl = struct {
    kind: VarKind = .var_,
    name: []const u8,
    init: ?*Node,
    using_kind: UsingKind = .none,
};

pub const FuncDecl = struct {
    name: []const u8,
    params: [][]const u8,
    param_defaults: []?*Node = &[_]?*Node{},
    /// See ParamParse.expected_argc — null means "params.len".
    expected_argc: ?u16 = null,
    rest_param: ?[]const u8 = null,
    body: []*Node,
    is_generator: bool = false,
    is_async: bool = false,
    is_strict: bool = false,
    source_text: ?[]const u8 = null,
};

pub const IfStmt = struct {
    test_: *Node,
    consequent: *Node,
    alternate: ?*Node,
};

pub const WhileStmt = struct {
    test_: *Node,
    body: *Node,
};

pub const DoWhileStmt = struct {
    body: *Node,
    test_: *Node,
};

pub const WithStmt = struct {
    object: *Node,
    body: *Node,
};

pub const ForStmt = struct {
    init: ?*Node,
    test_: ?*Node,
    update: ?*Node,
    body: *Node,
};

/// Phase 4a: catch clause for try statement.
pub const CatchClause = struct {
    param_name: []const u8,
    body: *Node,
};

/// Phase 4a: try/catch/finally statement.
pub const TryStmt = struct {
    block: *Node,
    handler: ?CatchClause,
    finalizer: ?*Node,
};

/// Phase 4d: for-in statement.
/// left: var_decl or identifier node (the loop variable)
/// right: expression (the object to iterate)
/// body: statement
pub const ForInStmt = struct {
    left: *Node,
    right: *Node,
    body: *Node,
    iterate_values: bool = false,
    /// `for await (x of it)`: consume via the async-iterator protocol, awaiting
    /// each step. Only valid inside an async function / async generator body.
    is_await: bool = false,
};

/// Phase 4d: single case in a switch statement.
pub const SwitchCase = struct {
    /// null => default case
    test_: ?*Node,
    body: []*Node,
};

/// Phase 4d: switch statement.
pub const SwitchStmt = struct {
    discriminant: *Node,
    cases: []SwitchCase,
};

/// Phase 4d: labeled statement.
pub const LabeledStmt = struct {
    name: []const u8,
    body: *Node,
};

test "AST types compile" {
    try std.testing.expect(true);
}
