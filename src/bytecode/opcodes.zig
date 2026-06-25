// SPDX-License-Identifier: Apache-2.0
//! Register-based bytecode instruction set for jsz Phase 2/3a/4a.
//! Encoding: byte stream, [op u8][operands packed little-endian].
//!
//! Operand layout table:
//!
//!  Opcode          | Bytes | Layout
//! -----------------+-------+----------------------------------------
//!  LOAD_K          |   4   | op, Rdst u8, Kidx u16-LE
//!  LOAD_TRUE       |   2   | op, Rdst u8
//!  LOAD_FALSE      |   2   | op, Rdst u8
//!  LOAD_NULL       |   2   | op, Rdst u8
//!  LOAD_UNDEF      |   2   | op, Rdst u8
//!  MOVE            |   3   | op, Rdst u8, Rsrc u8
//!  GET_GLOBAL      |   4   | op, Rdst u8, Kname u16-LE  (constant is string)
//!  SET_GLOBAL      |   4   | op, Kname u16-LE, Rsrc u8
//!  GET_LOCAL       |   3   | op, Rdst u8, slot u8
//!  SET_LOCAL       |   3   | op, slot u8, Rsrc u8
//!  ADD             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  SUB             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  MUL             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  DIV             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  MOD             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  BIT_AND         |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  BIT_OR          |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  BIT_XOR         |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  SHL             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  SHR             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  USHR            |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  NEG             |   3   | op, Rdst u8, Rsrc u8
//!  BIT_NOT         |   3   | op, Rdst u8, Rsrc u8
//!  INC             |   3   | op, Rdst u8, Rsrc u8   (Rdst = ToNumber(Rsrc)+1)
//!  DEC             |   3   | op, Rdst u8, Rsrc u8   (Rdst = ToNumber(Rsrc)-1)
//!  EQ              |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  NEQ             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  SEQ             |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  SNEQ            |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  LT              |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  LE              |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  GT              |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  GE              |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  NOT             |   3   | op, Rdst u8, Rsrc u8
//!  TYPEOF          |   3   | op, Rdst u8, Rsrc u8
//!  JMP             |   3   | op, offset i16-LE (relative to next instr)
//!  JMP_IF_TRUE     |   4   | op, Rcond u8, offset i16-LE
//!  JMP_IF_FALSE    |   4   | op, Rcond u8, offset i16-LE
//!  JMP_IF_NULLISH  |   4   | op, Rcond u8, offset i16-LE
//!  JMP_IF_NOT_NULLISH | 4  | op, Rcond u8, offset i16-LE
//!  JSEQ            |   5   | op, Rlhs u8, Rrhs u8, offset i16-LE
//!  JGE             |   5   | op, Rlhs u8, Rrhs u8, offset i16-LE
//!  NEW_CLOSURE     |   4   | op, Rdst u8, funcIdx u16-LE
//!  CALL            |   4   | op, base u8, nargs u8, retDst u8
//!  RETURN          |   2   | op, Rsrc u8
//!  RETURN_UNDEF    |   1   | op
//!  HALT            |   1   | op
//!  --- Phase 3a ---
//!  NEW_OBJECT      |   2   | op, Rdst u8
//!  NEW_ARRAY       |   3   | op, Rdst u8, lenU8 u8  (pre-allocated length hint)
//!  SET_PROP        |   5   | op, Robj u8, KnameU16 u16-LE, Rval u8
//!  GET_PROP        |   5   | op, Rdst u8, Robj u8, KnameU16 u16-LE
//!  SET_PROP_DYN    |   4   | op, Robj u8, Rkey u8, Rval u8
//!  GET_PROP_DYN    |   4   | op, Rdst u8, Robj u8, Rkey u8
//!  GET_THIS        |   2   | op, Rdst u8
//!  METHOD_CALL     |   4   | op, base u8, nargs u8, retDst u8
//!                  |       |   R[base] = this object, R[base+1] = function value
//!                  |       |   R[base+2..base+1+nargs] = args
//!  --- Phase 4a ---
//!  THROW           |   2   | op, Rsrc u8
//!  PUSH_TRY        |   4   | op, Rexc u8, handler_offset i16-LE
//!                  |       |   Rexc = register for caught value; handler_offset = absolute PC
//!                  |       |   Rexc=0xFF means no catch param (finally-only try)
//!  POP_TRY         |   1   | op  (remove top try entry, normal exit from try block)
//!  NEW_INSTANCE    |   4   | op, Rdst u8, base u8, nargs u8
//!                  |       |   R[base] = constructor, R[base+1..base+nargs] = args
//!  INSTANCEOF      |   4   | op, Rdst u8, Rlhs u8, Rrhs u8
//!  --- Phase 4d ---
//!  GET_KEYS        |   3   | op, Rdst u8, Robj u8

const std = @import("std");

pub const Op = enum(u8) {
    LOAD_K,
    LOAD_TRUE,
    LOAD_FALSE,
    LOAD_NULL,
    LOAD_UNDEF,
    MOVE,
    GET_GLOBAL,
    SET_GLOBAL,
    GET_LOCAL,
    SET_LOCAL,
    ADD,
    SUB,
    MUL,
    DIV,
    MOD,
    EXP,
    BIT_AND,
    BIT_OR,
    BIT_XOR,
    SHL,
    SHR,
    USHR,
    NEG,
    BIT_NOT,
    INC,
    DEC,
    EQ,
    NEQ,
    SEQ,
    SNEQ,
    LT,
    LE,
    GT,
    GE,
    NOT,
    TYPEOF,
    JMP,
    JMP_IF_TRUE,
    JMP_IF_FALSE,
    // ES2020: nullish-coalescing / optional-chaining short-circuit jumps.
    JMP_IF_NULLISH,
    JMP_IF_NOT_NULLISH,
    JSEQ,
    JGE,
    NEW_CLOSURE,
    CALL,
    RETURN,
    RETURN_UNDEF,
    HALT,
    // Phase 3a opcodes
    NEW_OBJECT,
    NEW_ARRAY,
    SET_PROP,
    GET_PROP,
    SET_PROP_DYN,
    GET_PROP_DYN,
    GET_THIS,
    METHOD_CALL,
    // Phase 4a opcodes
    THROW,
    PUSH_TRY,
    POP_TRY,
    NEW_INSTANCE,
    INSTANCEOF,
    // Phase 4d opcodes
    /// GET_KEYS: op, Rdst u8, Robj u8
    /// Rdst receives a JS array of enumerable own-property key strings of R[Robj].
    GET_KEYS,
    /// DEFINE_GLOBAL: same encoding as SET_GLOBAL (op, Kname u16-LE, Rsrc u8).
    /// Always defines/assigns without strict-mode ReferenceError — used for
    /// catch-variable binding and var declarations in strict functions.
    DEFINE_GLOBAL,
    // Phase 8 opcodes
    /// TAIL_CALL: same encoding as CALL (op, Rbase u8, nargs u8, Rret u8).
    /// ES2015 proper tail call (strict mode only). When the callee is a bytecode
    /// function the current call frame is reused in place rather than pushing a
    /// new one, giving O(1) call-stack growth for tail recursion. For native /
    /// bound callees it degrades to a normal call followed by a return.
    TAIL_CALL,
    /// DEBUGGER: op only (1 byte). Compiled from the `debugger;` statement.
    /// Fires the installed debug hook (runtime/debugger.zig active_hook); a
    /// no-op when no debugger is attached.
    DEBUGGER,
    /// W2: YIELD — op, Rval u8 (2 bytes). Suspends the current generator frame,
    /// surfacing R[Rval] as the yielded value. On resume the value passed to
    /// .next(v) is written back into R[Rval] (so `x = yield e` works).
    YIELD,
    /// TAIL_METHOD_CALL: same encoding as METHOD_CALL (op, Rbase u8, nargs u8,
    /// Rret u8) with R[base]=this, R[base+1]=callee. Member-position proper tail
    /// call (`return obj.m()`, strict mode): reuses the current frame in place
    /// when the resolved callee is a plain bytecode function; otherwise degrades
    /// to a normal method call followed by a return.
    TAIL_METHOD_CALL,
    /// DEFINE_ACCESSOR: op, Robj u8, Kname u16-LE, kind u8 (0=get,1=set), Rfn u8.
    /// Installs an accessor (getter if kind==0, setter if kind==1) named Kname on
    /// R[Robj], merging into an existing accessor holder for the same key.
    DEFINE_ACCESSOR,
    /// DEFINE_ACCESSOR_DYN: op, Robj u8, Rkey u8, kind u8 (0=get,1=set), Rfn u8.
    /// Like DEFINE_ACCESSOR but the key is a runtime value in R[Rkey] (string or
    /// symbol) — used for computed accessor keys `{ get [expr]() {} }`.
    DEFINE_ACCESSOR_DYN,
    /// ARRAY_APPEND: op, Rarr u8, Rval u8 (3 bytes). Appends R[Rval] to the array
    /// R[Rarr] at its current length (used for array-literal elements when the
    /// literal contains a spread, so indices are dynamic).
    ARRAY_APPEND,
    /// ARRAY_SPREAD: op, Rarr u8, Riter u8 (3 bytes). Iterates R[Riter] via the
    /// iterator protocol and appends every produced value to the array R[Rarr]
    /// (implements `[...iterable]` in array literals).
    ARRAY_SPREAD,
    /// IN: op, Rdst u8, Rkey u8, Robj u8 (4 bytes). Rdst = HasProperty(R[Robj],
    /// R[Rkey]) — the `key in obj` operator (proto-chain walk; Proxy `has` trap).
    IN,
    /// DELETE_PROP: op, Rdst u8, Robj u8, Rkey u8 (4 bytes). Deletes own property
    /// R[Rkey] from R[Robj]; Rdst = boolean result (the `delete obj[key]`
    /// operator; Proxy `deleteProperty` trap).
    DELETE_PROP,
    /// CALL_SPREAD: op, Rcallee u8, Rthis u8, Rargs u8, Rdst u8 (5 bytes). Calls
    /// R[Rcallee] with `this` = R[Rthis] and arguments unpacked from the array
    /// R[Rargs]; result into R[Rdst]. Used for calls containing a spread arg
    /// (`f(...xs)`, `obj.m(a, ...xs)`). Operand registers need not be contiguous.
    CALL_SPREAD,
    /// Tolerant global read: like GET_GLOBAL but yields `undefined` (never a
    /// ReferenceError) when the name resolves nowhere. Emitted only for the
    /// operand of `typeof <identifier>`, where an undeclared name must be safe.
    GET_GLOBAL_OPT,
    /// HOIST_VAR | 3 | op, Kname u16-LE. Defines `name` = undefined in the
    /// current env if it has no own binding yet (var/function-decl hoisting).
    /// Never clobbers a parameter or an already-defined binding.
    HOIST_VAR,
    /// HOIST_LEX | 3 | op, Kname u16-LE. Declares `name` as an uninitialized
    /// lexical binding (TDZ) in the current env if it has no own binding yet.
    /// Used for `let`/`const` declarations and module import bindings.
    HOIST_LEX,
    /// INIT_LEX | 5 | op, Kname u16-LE, Rsrc u8, IsConst u8. Initializes an
    /// existing lexical binding `name` in the current env with the value in
    /// R[Rsrc], taking it out of TDZ. IsConst=1 upgrades the binding to const_.
    INIT_LEX,
    /// ENTER_SCOPE | 1 | op. Push a fresh child `Environment` onto the current
    /// frame (block-scoped lexical bindings live here). Paired with EXIT_SCOPE.
    ENTER_SCOPE,
    /// EXIT_SCOPE | 1 | op. Pop the current frame env back to its parent,
    /// discarding the most recent block scope's bindings.
    EXIT_SCOPE,
};

/// Returns the number of bytes an encoded instruction occupies (op byte + operands).
pub fn instrSize(op: Op) usize {
    return switch (op) {
        .LOAD_K => 4,
        .LOAD_TRUE => 2,
        .LOAD_FALSE => 2,
        .LOAD_NULL => 2,
        .LOAD_UNDEF => 2,
        .MOVE => 3,
        .GET_GLOBAL => 4,
        .GET_GLOBAL_OPT => 4,
        .HOIST_VAR => 3,
        .HOIST_LEX => 3,
        .INIT_LEX => 5,
        .ENTER_SCOPE => 1,
        .EXIT_SCOPE => 1,
        .SET_GLOBAL => 4,
        .GET_LOCAL => 3,
        .SET_LOCAL => 3,
        .ADD => 4,
        .SUB => 4,
        .MUL => 4,
        .DIV => 4,
        .MOD => 4,
        .EXP => 4,
        .BIT_AND => 4,
        .BIT_OR => 4,
        .BIT_XOR => 4,
        .SHL => 4,
        .SHR => 4,
        .USHR => 4,
        .NEG => 3,
        .BIT_NOT => 3,
        .INC => 3,
        .DEC => 3,
        .EQ => 4,
        .NEQ => 4,
        .SEQ => 4,
        .SNEQ => 4,
        .LT => 4,
        .LE => 4,
        .GT => 4,
        .GE => 4,
        .NOT => 3,
        .TYPEOF => 3,
        .JMP => 3,
        .JMP_IF_TRUE => 4,
        .JMP_IF_FALSE => 4,
        .JMP_IF_NULLISH => 4,
        .JMP_IF_NOT_NULLISH => 4,
        .JSEQ => 5,
        .JGE => 5,
        .NEW_CLOSURE => 4,
        .CALL => 4,
        .RETURN => 2,
        .RETURN_UNDEF => 1,
        .HALT => 1,
        // Phase 3a
        .NEW_OBJECT => 2,
        .NEW_ARRAY => 3,
        .SET_PROP => 5,
        .GET_PROP => 5,
        .SET_PROP_DYN => 4,
        .GET_PROP_DYN => 4,
        .GET_THIS => 2,
        .METHOD_CALL => 4,
        // Phase 4a
        .THROW => 2,
        .PUSH_TRY => 4,
        .POP_TRY => 1,
        .NEW_INSTANCE => 4,
        .INSTANCEOF => 4,
        // Phase 4d
        .GET_KEYS => 3,
        .DEFINE_GLOBAL => 4,
        // Phase 8
        .TAIL_CALL => 4,
        .DEBUGGER => 1,
        .YIELD => 2,
        .TAIL_METHOD_CALL => 4,
        .DEFINE_ACCESSOR => 6,
        .DEFINE_ACCESSOR_DYN => 5,
        .ARRAY_APPEND => 3,
        .ARRAY_SPREAD => 3,
        .IN => 4,
        .DELETE_PROP => 4,
        .CALL_SPREAD => 5,
    };
}

test "Op enum exists" {
    const op: Op = .LOAD_K;
    try std.testing.expect(op == .LOAD_K);
    try std.testing.expect(@intFromEnum(Op.HALT) < 255);
}

test "JIT contract: int-subset opcode ordinals are pinned" {
    // The Phase 12 native int-block compiler (jit-native/src/lib.rs +
    // src/jit/native.zig) hardcodes these byte values. Reordering the Op enum
    // would silently miscompile JITed code — fail loudly here instead.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Op.LOAD_K));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Op.LOAD_TRUE));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Op.LOAD_FALSE));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Op.LOAD_UNDEF));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Op.MOVE));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Op.GET_GLOBAL));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(Op.SET_GLOBAL));
    try std.testing.expectEqual(@as(u8, 10), @intFromEnum(Op.ADD));
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(Op.SUB));
    try std.testing.expectEqual(@as(u8, 12), @intFromEnum(Op.MUL));
    try std.testing.expectEqual(@as(u8, 24), @intFromEnum(Op.INC));
    try std.testing.expectEqual(@as(u8, 25), @intFromEnum(Op.DEC));
    try std.testing.expectEqual(@as(u8, 26), @intFromEnum(Op.EQ));
    try std.testing.expectEqual(@as(u8, 27), @intFromEnum(Op.NEQ));
    try std.testing.expectEqual(@as(u8, 28), @intFromEnum(Op.SEQ));
    try std.testing.expectEqual(@as(u8, 29), @intFromEnum(Op.SNEQ));
    try std.testing.expectEqual(@as(u8, 30), @intFromEnum(Op.LT));
    try std.testing.expectEqual(@as(u8, 31), @intFromEnum(Op.LE));
    try std.testing.expectEqual(@as(u8, 32), @intFromEnum(Op.GT));
    try std.testing.expectEqual(@as(u8, 33), @intFromEnum(Op.GE));
    try std.testing.expectEqual(@as(u8, 34), @intFromEnum(Op.NOT));
    try std.testing.expectEqual(@as(u8, 36), @intFromEnum(Op.JMP));
    try std.testing.expectEqual(@as(u8, 37), @intFromEnum(Op.JMP_IF_TRUE));
    try std.testing.expectEqual(@as(u8, 38), @intFromEnum(Op.JMP_IF_FALSE));
    try std.testing.expectEqual(@as(u8, 44), @intFromEnum(Op.CALL));
    try std.testing.expectEqual(@as(u8, 45), @intFromEnum(Op.RETURN));
    try std.testing.expectEqual(@as(u8, 46), @intFromEnum(Op.RETURN_UNDEF));
    try std.testing.expectEqual(@as(u8, 47), @intFromEnum(Op.HALT));
    try std.testing.expectEqual(@as(u8, 62), @intFromEnum(Op.DEFINE_GLOBAL));
    try std.testing.expectEqual(@as(u8, 74), @intFromEnum(Op.HOIST_VAR));
}

test "instrSize LOAD_K is 4" {
    try std.testing.expectEqual(@as(usize, 4), instrSize(.LOAD_K));
}

test "instrSize Phase3a opcodes" {
    try std.testing.expectEqual(@as(usize, 2), instrSize(.NEW_OBJECT));
    try std.testing.expectEqual(@as(usize, 3), instrSize(.NEW_ARRAY));
    try std.testing.expectEqual(@as(usize, 5), instrSize(.SET_PROP));
    try std.testing.expectEqual(@as(usize, 5), instrSize(.GET_PROP));
    try std.testing.expectEqual(@as(usize, 4), instrSize(.SET_PROP_DYN));
    try std.testing.expectEqual(@as(usize, 4), instrSize(.GET_PROP_DYN));
    try std.testing.expectEqual(@as(usize, 2), instrSize(.GET_THIS));
    try std.testing.expectEqual(@as(usize, 4), instrSize(.METHOD_CALL));
}
