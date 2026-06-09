// SPDX-License-Identifier: MIT
//! Phase 9 baseline JIT native backend — a minimal C-ABI surface over
//! `cranelift-jit`. This is the first native-codegen milestone: prove that the
//! Zig side can drive Cranelift to emit real machine code and call it.
//!
//! Exposed to Zig via `extern "C"` (see `src/jit/native.zig`):
//!   - `jsz_clif_compile_add()`    -> fn(i64, i64) -> i64   (native `iadd`)
//!   - `jsz_clif_compile_const(k)` -> fn() -> i64           (native const return)
//!   - `jsz_clif_available()`      -> 1                      (backend linked probe)
//!
//! The compiled code lives inside a leaked `JITModule` so the executable
//! mapping stays valid for the process lifetime (fine for a one-shot proof;
//! a real tier would own the module and free on deopt/blacklist).

use std::ffi::c_void;

use cranelift_codegen::ir::condcodes::{FloatCC, IntCC};
use cranelift_codegen::ir::{types, AbiParam, Block, InstBuilder, MemFlags, Value};
use cranelift_codegen::settings::{self, Configurable};
use cranelift_frontend::{FunctionBuilder, FunctionBuilderContext};
use cranelift_jit::{JITBuilder, JITModule};
use cranelift_module::{default_libcall_names, Linkage, Module};

/// Build a fresh JIT module configured for the host ISA.
fn make_module() -> Option<JITModule> {
    let mut flag_builder = settings::builder();
    // Not generating position-independent code; calling directly via raw ptr.
    flag_builder.set("use_colocated_libcalls", "false").ok()?;
    flag_builder.set("is_pic", "false").ok()?;
    let isa_builder = cranelift_native::builder().ok()?;
    let isa = isa_builder
        .finish(settings::Flags::new(flag_builder))
        .ok()?;
    let builder = JITBuilder::with_isa(isa, default_libcall_names());
    Some(JITModule::new(builder))
}

/// Compile `fn(i64, i64) -> i64` returning `a + b`. Returns a raw code pointer
/// (null on failure). The module is leaked so the mapping survives.
#[unsafe(no_mangle)]
pub extern "C" fn jsz_clif_compile_add() -> *const c_void {
    let Some(mut module) = make_module() else {
        return std::ptr::null();
    };

    let mut ctx = module.make_context();
    let mut sig = module.make_signature();
    sig.params.push(AbiParam::new(types::I64));
    sig.params.push(AbiParam::new(types::I64));
    sig.returns.push(AbiParam::new(types::I64));
    ctx.func.signature = sig;

    let mut fbctx = FunctionBuilderContext::new();
    {
        let mut fb = FunctionBuilder::new(&mut ctx.func, &mut fbctx);
        let block = fb.create_block();
        fb.append_block_params_for_function_params(block);
        fb.switch_to_block(block);
        fb.seal_block(block);
        let a = fb.block_params(block)[0];
        let b = fb.block_params(block)[1];
        let sum = fb.ins().iadd(a, b);
        fb.ins().return_(&[sum]);
        fb.finalize();
    }

    let id = match module.declare_function("jsz_add", Linkage::Export, &ctx.func.signature) {
        Ok(id) => id,
        Err(_) => return std::ptr::null(),
    };
    if module.define_function(id, &mut ctx).is_err() {
        return std::ptr::null();
    }
    module.clear_context(&mut ctx);
    if module.finalize_definitions().is_err() {
        return std::ptr::null();
    }
    let code = module.get_finalized_function(id);
    // Keep the executable mapping alive for the process lifetime.
    std::mem::forget(module);
    code as *const c_void
}

/// Compile `fn() -> i64` returning the constant `k`. Returns null on failure.
#[unsafe(no_mangle)]
pub extern "C" fn jsz_clif_compile_const(k: i64) -> *const c_void {
    let Some(mut module) = make_module() else {
        return std::ptr::null();
    };

    let mut ctx = module.make_context();
    let mut sig = module.make_signature();
    sig.returns.push(AbiParam::new(types::I64));
    ctx.func.signature = sig;

    let mut fbctx = FunctionBuilderContext::new();
    {
        let mut fb = FunctionBuilder::new(&mut ctx.func, &mut fbctx);
        let block = fb.create_block();
        fb.switch_to_block(block);
        fb.seal_block(block);
        let v = fb.ins().iconst(types::I64, k);
        fb.ins().return_(&[v]);
        fb.finalize();
    }

    let id = match module.declare_function("jsz_const", Linkage::Export, &ctx.func.signature) {
        Ok(id) => id,
        Err(_) => return std::ptr::null(),
    };
    if module.define_function(id, &mut ctx).is_err() {
        return std::ptr::null();
    }
    module.clear_context(&mut ctx);
    if module.finalize_definitions().is_err() {
        return std::ptr::null();
    }
    let code = module.get_finalized_function(id);
    std::mem::forget(module);
    code as *const c_void
}

/// Phase 9 step 4 — monomorphic-int hot loop.
///
/// Compile `fn(start: i64, limit: i64, step: i64) -> i64` implementing
/// `var i = start; while (i < limit) i += step; return i;` entirely in unboxed
/// i64 native code. This is the canonical shape a hot counter loop reduces to
/// after the JIT unboxes the loop-carried value at the region boundary — the
/// IR has a real loop: an entry, a header with the `i < limit` guard branch, a
/// body that adds `step` and jumps back (the back-edge), and an exit.
///
/// The boxing/unboxing and the *type* guard (is the JS value an integral
/// number?) live on the Zig side at the region boundary; this kernel is the
/// already-unboxed inner loop. Returns null on codegen failure.
#[unsafe(no_mangle)]
pub extern "C" fn jsz_clif_compile_count_loop() -> *const c_void {
    let Some(mut module) = make_module() else {
        return std::ptr::null();
    };

    let mut ctx = module.make_context();
    let mut sig = module.make_signature();
    sig.params.push(AbiParam::new(types::I64)); // start
    sig.params.push(AbiParam::new(types::I64)); // limit
    sig.params.push(AbiParam::new(types::I64)); // step
    sig.returns.push(AbiParam::new(types::I64));
    ctx.func.signature = sig;

    let mut fbctx = FunctionBuilderContext::new();
    {
        let mut fb = FunctionBuilder::new(&mut ctx.func, &mut fbctx);
        let entry = fb.create_block();
        let header = fb.create_block();
        let body = fb.create_block();
        let exit = fb.create_block();
        // Loop-carried induction variable `i` is a block param of each block.
        fb.append_block_params_for_function_params(entry);
        fb.append_block_param(header, types::I64);
        fb.append_block_param(body, types::I64);
        fb.append_block_param(exit, types::I64);

        // entry: jump header(start). limit/step (entry params) dominate the rest.
        fb.switch_to_block(entry);
        let start = fb.block_params(entry)[0];
        let limit = fb.block_params(entry)[1];
        let step = fb.block_params(entry)[2];
        fb.ins().jump(header, &[start.into()]);

        // header(i): if i < limit -> body(i) else exit(i)
        fb.switch_to_block(header);
        let i_hdr = fb.block_params(header)[0];
        let cond = fb.ins().icmp(IntCC::SignedLessThan, i_hdr, limit);
        fb.ins()
            .brif(cond, body, &[i_hdr.into()], exit, &[i_hdr.into()]);

        // body(i): i2 = i + step; jump header(i2)   <- the back-edge
        fb.switch_to_block(body);
        let i_body = fb.block_params(body)[0];
        let i_next = fb.ins().iadd(i_body, step);
        fb.ins().jump(header, &[i_next.into()]);

        // exit(i): return i
        fb.switch_to_block(exit);
        let i_exit = fb.block_params(exit)[0];
        fb.ins().return_(&[i_exit]);

        fb.seal_block(entry);
        fb.seal_block(header);
        fb.seal_block(body);
        fb.seal_block(exit);
        fb.finalize();
    }

    let id = match module.declare_function("jsz_count_loop", Linkage::Export, &ctx.func.signature)
    {
        Ok(id) => id,
        Err(_) => return std::ptr::null(),
    };
    if module.define_function(id, &mut ctx).is_err() {
        return std::ptr::null();
    }
    module.clear_context(&mut ctx);
    if module.finalize_definitions().is_err() {
        return std::ptr::null();
    }
    let code = module.get_finalized_function(id);
    std::mem::forget(module);
    code as *const c_void
}

/// Phase 9 step 4 — per-op type guard + deopt exit.
///
/// Compile `fn(a: i64, b: i64, a_is_int: i32, b_is_int: i32, deopt: *mut i32) -> i64`:
/// if both operands are flagged integral, return `a + b`; otherwise write `1`
/// through `deopt` and return `0`. This models the speculative fast path a JIT
/// emits for `a + b`: a type guard whose failure branches to a deopt trampoline
/// (here, just setting the flag) instead of computing. The IR has the guard
/// `brif` splitting into an `ok` block and a `deopt` block.
///
/// Returns null on codegen failure.
#[unsafe(no_mangle)]
pub extern "C" fn jsz_clif_compile_guarded_iadd() -> *const c_void {
    let Some(mut module) = make_module() else {
        return std::ptr::null();
    };
    let ptr_ty = module.target_config().pointer_type();

    let mut ctx = module.make_context();
    let mut sig = module.make_signature();
    sig.params.push(AbiParam::new(types::I64)); // a
    sig.params.push(AbiParam::new(types::I64)); // b
    sig.params.push(AbiParam::new(types::I32)); // a_is_int
    sig.params.push(AbiParam::new(types::I32)); // b_is_int
    sig.params.push(AbiParam::new(ptr_ty)); // deopt: *mut i32
    sig.returns.push(AbiParam::new(types::I64));
    ctx.func.signature = sig;

    let mut fbctx = FunctionBuilderContext::new();
    {
        let mut fb = FunctionBuilder::new(&mut ctx.func, &mut fbctx);
        let entry = fb.create_block();
        let ok = fb.create_block();
        let deopt = fb.create_block();
        fb.append_block_params_for_function_params(entry);

        fb.switch_to_block(entry);
        let a = fb.block_params(entry)[0];
        let b = fb.block_params(entry)[1];
        let a_is_int = fb.block_params(entry)[2];
        let b_is_int = fb.block_params(entry)[3];
        let deopt_ptr = fb.block_params(entry)[4];
        // guard = a_is_int & b_is_int  (nonzero => take fast path)
        let guard = fb.ins().band(a_is_int, b_is_int);
        fb.ins().brif(guard, ok, &[], deopt, &[]);

        // ok: return a + b
        fb.switch_to_block(ok);
        let sum = fb.ins().iadd(a, b);
        fb.ins().return_(&[sum]);

        // deopt: *deopt = 1; return 0
        fb.switch_to_block(deopt);
        let one = fb.ins().iconst(types::I32, 1);
        fb.ins().store(MemFlags::trusted(), one, deopt_ptr, 0);
        let zero = fb.ins().iconst(types::I64, 0);
        fb.ins().return_(&[zero]);

        fb.seal_block(entry);
        fb.seal_block(ok);
        fb.seal_block(deopt);
        fb.finalize();
    }

    let id =
        match module.declare_function("jsz_guarded_iadd", Linkage::Export, &ctx.func.signature) {
            Ok(id) => id,
            Err(_) => return std::ptr::null(),
        };
    if module.define_function(id, &mut ctx).is_err() {
        return std::ptr::null();
    }
    module.clear_context(&mut ctx);
    if module.finalize_definitions().is_err() {
        return std::ptr::null();
    }
    let code = module.get_finalized_function(id);
    std::mem::forget(module);
    code as *const c_void
}

/// Probe that the native backend is linked. Always returns 1 when present.
#[unsafe(no_mangle)]
pub extern "C" fn jsz_clif_available() -> i32 {
    1
}

// ===================================================================
// Phase 12 — general bytecode -> Cranelift IR translator (int subset).
//
// `jsz_clif_compile_int_block` walks a `BcFunction.chunk` byte buffer and emits
// Cranelift IR for the *monomorphic-integer* opcode subset, producing a native
// `fn(regs: *mut i64, consts: *const i64) -> i64`. Unlike the fixed kernels
// above, this compiles ARBITRARY control flow (branches + loops) over a register
// file — the first step toward full JIT (`compile bc_function to Cranelift IR`).
//
// Model: the register file is kept in memory (the `regs` pointer); each operand
// access is an i64 load/store. This sidesteps SSA phi construction for arbitrary
// CFGs — Cranelift's own passes promote what it can. SMIs are assumed already
// unboxed to i64 by the caller (the boxing ABI + type guards + OSR live on the
// Zig side and are layered on later). Any unsupported opcode aborts compilation
// (returns null) so the caller falls back to the interpreter — a coarse deopt.
//
// Opcode numbers MUST match `src/bytecode/opcodes.zig` (Op enum order). The Zig
// FFI test builds bytecode from the real `@intFromEnum(Op.*)` values, so a
// reorder there fails the test loudly.
// ===================================================================

// Opcode byte values (mirror of opcodes.zig Op enum ordinals).
const OP_LOAD_K: u8 = 0;
const OP_LOAD_TRUE: u8 = 1;
const OP_LOAD_FALSE: u8 = 2;
const OP_LOAD_UNDEF: u8 = 4;
const OP_MOVE: u8 = 5;
const OP_GET_GLOBAL: u8 = 6;
const OP_SET_GLOBAL: u8 = 7;
const OP_DEFINE_GLOBAL: u8 = 62;
const OP_HOIST_VAR: u8 = 74;
const OP_ADD: u8 = 10;
const OP_SUB: u8 = 11;
const OP_MUL: u8 = 12;
const OP_INC: u8 = 24;
const OP_DEC: u8 = 25;
const OP_EQ: u8 = 26;
const OP_NEQ: u8 = 27;
const OP_SEQ: u8 = 28;
const OP_SNEQ: u8 = 29;
const OP_LT: u8 = 30;
const OP_LE: u8 = 31;
const OP_GT: u8 = 32;
const OP_GE: u8 = 33;
const OP_NOT: u8 = 34;
const OP_CALL: u8 = 44;
const OP_JMP: u8 = 36;
const OP_JMP_IF_TRUE: u8 = 37;
const OP_JMP_IF_FALSE: u8 = 38;
const OP_RETURN: u8 = 45;
const OP_RETURN_UNDEF: u8 = 46;
const OP_HALT: u8 = 47;
const OP_SET_PROP: u8 = 50;
const OP_GET_PROP: u8 = 51;

/// One property-access site (boxed tier S3): at bytecode offset `pc`, a `GET_PROP`
/// reads property `key` consulting the live inline cache `ic`. The native code
/// passes these to the Zig fast-path helper, which mirrors the interpreter's
/// non-re-entrant IC lookup (own mono/poly/mega + proto-chain data) and sets
/// `*miss` (→ coarse deopt) for anything it can't resolve without running JS
/// (accessors, uncached shapes, non-objects).
#[repr(C)]
#[derive(Clone, Copy)]
pub struct PropSite {
    pub pc: u32,
    pub key_len: u32,
    pub key_ptr: u64,
    pub ic_ptr: u64,
}

/// Encoded instruction byte length for the supported opcodes; `None` aborts.
fn int_instr_size(op: u8) -> Option<usize> {
    Some(match op {
        OP_LOAD_K => 4,
        OP_LOAD_TRUE | OP_LOAD_FALSE | OP_LOAD_UNDEF => 2,
        OP_MOVE => 3,
        OP_GET_GLOBAL => 4,
        OP_SET_GLOBAL | OP_DEFINE_GLOBAL => 4,
        OP_HOIST_VAR => 3,
        OP_ADD | OP_SUB | OP_MUL => 4,
        OP_INC | OP_DEC | OP_NOT => 3,
        OP_EQ | OP_NEQ | OP_SEQ | OP_SNEQ | OP_LT | OP_LE | OP_GT | OP_GE => 4,
        OP_JMP => 3,
        OP_JMP_IF_TRUE | OP_JMP_IF_FALSE => 4,
        OP_RETURN => 2,
        OP_RETURN_UNDEF | OP_HALT => 1,
        OP_GET_PROP => 5, // op, Rdst, Robj, Kname:u16
        OP_SET_PROP => 5, // op, Robj, Kname:u16, Rval
        OP_CALL => 4, // op, base, nargs, retDst
        _ => return None, // unsupported opcode -> bail (interpreter fallback)
    })
}

fn read_i16_le(code: &[u8], at: usize) -> i16 {
    (code[at] as u16 | ((code[at + 1] as u16) << 8)) as i16
}

fn read_u16_le(code: &[u8], at: usize) -> u16 {
    code[at] as u16 | ((code[at + 1] as u16) << 8)
}

/// True for opcodes that end a basic block (no fallthrough, or a branch).
fn is_terminator(op: u8) -> bool {
    matches!(
        op,
        OP_JMP | OP_JMP_IF_TRUE | OP_JMP_IF_FALSE | OP_RETURN | OP_RETURN_UNDEF | OP_HALT
    )
}

/// Compile a monomorphic-int bytecode function to native code.
///
/// Returns `fn(regs: *mut i64, consts: *const i64, locals: *mut i64,
/// deopt: *mut i32) -> i64` (the RETURNed value), or null if the bytecode uses
/// an unsupported opcode or references a non-local name.
///
/// `kidx_to_slot[k]` maps a constant-pool index `k` (the name operand of
/// `GET_GLOBAL`/`SET_GLOBAL`/`DEFINE_GLOBAL`) to a dense `locals` slot, or a
/// negative value when that name is NOT a monomorphic-int function local (a true
/// global, a closure-captured var, etc.) — any such access aborts compilation so
/// the caller keeps interpreting. `locals` holds the unboxed-i64 function-local
/// variables; the caller marshals them in and out around the call.
///
/// Every arithmetic op guards its result against ±2^53 (the f64-exact integer
/// range). If any intermediate escapes, the function writes `1` through `deopt`
/// and returns early; the caller then discards the result and re-runs the call in
/// the interpreter (sound because the JITed function is a side-effect-free leaf).
/// This makes the fast path bit-exact with JS number semantics — no speculative
/// large-integer rounding boundary remains.
///
/// # Safety
/// `code`/`kidx_to_slot` must point to `len`/`n_kidx` valid elements for the call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jsz_clif_compile_int_block(
    code: *const u8,
    len: usize,
    kidx_to_slot: *const i32,
    n_kidx: usize,
) -> *const c_void {
    if code.is_null() || len == 0 {
        return std::ptr::null();
    }
    let code = unsafe { std::slice::from_raw_parts(code, len) };
    let slots: &[i32] = if kidx_to_slot.is_null() || n_kidx == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(kidx_to_slot, n_kidx) }
    };
    compile_int_block_impl(code, slots, false, &[], 0, 0, 0).unwrap_or(std::ptr::null())
}

/// Phase 12 boxed tier — compile the same opcode subset as
/// `jsz_clif_compile_int_block`, but treating every `regs`/`locals`/`consts` slot
/// as a raw boxed `Value` (`bits: u64`, WebKit NaN-box) instead of an unboxed i64.
/// Arithmetic guards both operands are SMI (else sets `deopt` and returns), runs
/// the i128 + 2^53 overflow guard, then re-boxes the result via `makeNumber`
/// semantics (SMI when it fits i32, else an offset-double). The returned value is
/// itself a boxed `Value`. This is the foundation of the non-leaf tier: the
/// register file now carries boxed values, so later slices can add property
/// access, calls, and full float arithmetic on the same ABI. See
/// docs/JIT_BOXED_TIER_PLAN.md.
///
/// # Safety
/// `code`/`kidx_to_slot` must point to `len`/`n_kidx` valid elements for the call.
/// `prop_sites`/`n_prop_sites` give the monomorphic property-access sites in this
/// region (see `PropSite`); `get_helper` is the address of the Zig
/// `jsz_jit_get_own(recv, shape, slot, miss)` fast-path callback the native code
/// invokes at each `GET_PROP` (it sets `*miss` and the region deopts on a miss).
/// Both are empty/0 when the region has no property access.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jsz_clif_compile_boxed_block(
    code: *const u8,
    len: usize,
    kidx_to_slot: *const i32,
    n_kidx: usize,
    prop_sites: *const PropSite,
    n_prop_sites: usize,
    get_helper: u64,
    set_helper: u64,
    call_helper: u64,
) -> *const c_void {
    if code.is_null() || len == 0 {
        return std::ptr::null();
    }
    let code = unsafe { std::slice::from_raw_parts(code, len) };
    let slots: &[i32] = if kidx_to_slot.is_null() || n_kidx == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(kidx_to_slot, n_kidx) }
    };
    let sites: &[PropSite] = if prop_sites.is_null() || n_prop_sites == 0 {
        &[]
    } else {
        unsafe { std::slice::from_raw_parts(prop_sites, n_prop_sites) }
    };
    compile_int_block_impl(code, slots, true, sites, get_helper, set_helper, call_helper)
        .unwrap_or(std::ptr::null())
}

/// Largest integer exactly representable as an f64 (`2^53`). A JS number stays
/// bit-exact with its i64 image only while it stays within ±this; the moment an
/// arithmetic result escapes the range, deferred i64 rounding would diverge from
/// per-op f64 rounding. So every arithmetic op guards its result against it.
const F64_SAFE_INT: i64 = 9_007_199_254_740_992;

/// Emit the per-op overflow guard. `val` is the i128 result of an arithmetic op
/// (operands sign-extended to i128 so the op itself can never wrap). If
/// |val| > 2^53 the guard branches to `deopt_block` (which flags + returns);
/// otherwise control continues in a fresh block where `val` is narrowed back to
/// i64. Returns `(narrowed_i64, continuation_block)` — the caller must set its
/// current block to the continuation.
fn guard_i128_to_i64(fb: &mut FunctionBuilder, deopt_block: Block, val: Value) -> (Value, Block) {
    let lim64 = fb.ins().iconst(types::I64, F64_SAFE_INT);
    let lim = fb.ins().sextend(types::I128, lim64);
    let neg = fb.ins().ineg(lim);
    let too_hi = fb.ins().icmp(IntCC::SignedGreaterThan, val, lim);
    let too_lo = fb.ins().icmp(IntCC::SignedLessThan, val, neg);
    let bad = fb.ins().bor(too_hi, too_lo);
    let cont = fb.create_block();
    fb.ins().brif(bad, deopt_block, &[], cont, &[]);
    fb.switch_to_block(cont);
    let narrowed = fb.ins().ireduce(types::I64, val);
    (narrowed, cont)
}

// ---- WebKit JSVALUE64 NaN-box ABI (mirror of src/value/value.zig). ----
// Pinned by a Zig comptime contract test on the Zig side.
const NUMBER_TAG: u64 = 0xfffe_0000_0000_0000;
const DOUBLE_ENCODE_OFFSET: i64 = 0x0002_0000_0000_0000; // 1 << 49
const NB_FALSE: i64 = 0x6;
const NB_TRUE: i64 = 0x7;
const I32_MIN_I64: i64 = -2147483648;
const I32_MAX_I64: i64 = 2147483647;

/// `(bits & NumberTag) == NumberTag` — true when `v` is an inline int32 SMI.
fn emit_is_smi(fb: &mut FunctionBuilder, v: Value) -> Value {
    let masked = fb.ins().band_imm(v, NUMBER_TAG as i64);
    fb.ins().icmp_imm(IntCC::Equal, masked, NUMBER_TAG as i64)
}

/// Decode an SMI payload: `sext_i64(i32(bits & 0xffffffff))`. Caller guards isSmi.
fn emit_unbox_smi(fb: &mut FunctionBuilder, v: Value) -> Value {
    let lo = fb.ins().band_imm(v, 0xffff_ffff);
    let i32v = fb.ins().ireduce(types::I32, lo);
    fb.ins().sextend(types::I64, i32v)
}

/// Box an i64 back to a `Value` exactly as `value.zig:makeNumber`: an SMI when it
/// fits i32, else an offset-double. Fragments the CFG (range branch) — returns
/// the boxed value and the merge block; the caller must set its current block.
fn emit_box_i64(fb: &mut FunctionBuilder, r: Value) -> (Value, Block) {
    let smi_blk = fb.create_block();
    let dbl_blk = fb.create_block();
    let done = fb.create_block();
    fb.append_block_param(done, types::I64);
    let ge = fb.ins().icmp_imm(IntCC::SignedGreaterThanOrEqual, r, I32_MIN_I64);
    let le = fb.ins().icmp_imm(IntCC::SignedLessThanOrEqual, r, I32_MAX_I64);
    let in_range = fb.ins().band(ge, le);
    fb.ins().brif(in_range, smi_blk, &[], dbl_blk, &[]);
    // SMI: NumberTag | (u32)r
    fb.switch_to_block(smi_blk);
    let lo = fb.ins().ireduce(types::I32, r);
    let lou = fb.ins().uextend(types::I64, lo);
    let smi = fb.ins().bor_imm(lou, NUMBER_TAG as i64);
    fb.ins().jump(done, &[smi.into()]);
    // Double: bitcast_u64((f64)r) + DoubleEncodeOffset
    fb.switch_to_block(dbl_blk);
    let d = fb.ins().fcvt_from_sint(types::F64, r);
    let dbits = fb.ins().bitcast(types::I64, MemFlags::new(), d);
    let boxed = fb.ins().iadd_imm(dbits, DOUBLE_ENCODE_OFFSET);
    fb.ins().jump(done, &[boxed.into()]);
    fb.switch_to_block(done);
    (fb.block_params(done)[0], done)
}

/// `(bits & NumberTag) != 0` — true when `v` is any number (SMI or double).
fn emit_is_number(fb: &mut FunctionBuilder, v: Value) -> Value {
    let masked = fb.ins().band_imm(v, NUMBER_TAG as i64);
    fb.ins().icmp_imm(IntCC::NotEqual, masked, 0)
}

/// Decode a boxed number to f64 (branchless select): SMI payload as f64, or the
/// offset-double. Caller guards `isNumber`.
fn emit_to_f64(fb: &mut FunctionBuilder, v: Value) -> Value {
    let is = emit_is_smi(fb, v);
    let xi = emit_unbox_smi(fb, v);
    let xf = fb.ins().fcvt_from_sint(types::F64, xi);
    let dbits = fb.ins().iadd_imm(v, -DOUBLE_ENCODE_OFFSET); // v - offset
    let df = fb.ins().bitcast(types::F64, MemFlags::new(), dbits);
    fb.ins().select(is, xf, df)
}

/// Box an f64 back to a `Value` exactly as `value.zig:makeNumber`: an SMI when it
/// is an integer in i32 range AND not `-0`, else an offset-double. Fragments the
/// CFG; returns the boxed value and the merge block.
fn emit_box_f64(fb: &mut FunctionBuilder, f: Value) -> (Value, Block) {
    let smi_blk = fb.create_block();
    let dbl_blk = fb.create_block();
    let done = fb.create_block();
    fb.append_block_param(done, types::I64);
    let tf = fb.ins().trunc(f);
    let is_int = fb.ins().fcmp(FloatCC::Equal, f, tf);
    let lo_c = fb.ins().f64const(I32_MIN_I64 as f64);
    let hi_c = fb.ins().f64const(I32_MAX_I64 as f64);
    let ge = fb.ins().fcmp(FloatCC::GreaterThanOrEqual, f, lo_c);
    let le = fb.ins().fcmp(FloatCC::LessThanOrEqual, f, hi_c);
    let int_and_ge = fb.ins().band(is_int, ge);
    let in_range = fb.ins().band(int_and_ge, le);
    // Exclude -0.0 (f == 0 with the sign bit set) — it must stay a double.
    let zero = fb.ins().f64const(0.0);
    let is_zero = fb.ins().fcmp(FloatCC::Equal, f, zero);
    let fbits = fb.ins().bitcast(types::I64, MemFlags::new(), f);
    let signed = fb.ins().icmp_imm(IntCC::SignedLessThan, fbits, 0);
    let neg_zero = fb.ins().band(is_zero, signed);
    let not_nz = fb.ins().bxor_imm(neg_zero, 1);
    let smi_ok = fb.ins().band(in_range, not_nz);
    fb.ins().brif(smi_ok, smi_blk, &[], dbl_blk, &[]);
    // SMI: NumberTag | (u32)(i32)f
    fb.switch_to_block(smi_blk);
    let i32v = fb.ins().fcvt_to_sint_sat(types::I32, f);
    let lou = fb.ins().uextend(types::I64, i32v);
    let smi = fb.ins().bor_imm(lou, NUMBER_TAG as i64);
    fb.ins().jump(done, &[smi.into()]);
    // Double: bitcast_u64(f) + DoubleEncodeOffset
    fb.switch_to_block(dbl_blk);
    let dbits = fb.ins().bitcast(types::I64, MemFlags::new(), f);
    let boxed = fb.ins().iadd_imm(dbits, DOUBLE_ENCODE_OFFSET);
    fb.ins().jump(done, &[boxed.into()]);
    fb.switch_to_block(done);
    (fb.block_params(done)[0], done)
}

/// Boxed binary number op (`+`/`-`/`*`) matching the interpreter's semantics:
/// guard both operands numeric (else deopt); when both are SMI use the exact i128
/// integer path with the 2^53 guard, otherwise compute in f64; re-box via
/// `makeNumber`. `MUL` whose integer result is `0` is routed through f64 so a JS
/// `-0` (e.g. `-1 * 0`) is preserved. Returns `(boxed, merge_block)`.
fn emit_boxed_num_binop(
    fb: &mut FunctionBuilder,
    deopt_block: Block,
    l: Value,
    r: Value,
    op: u8,
) -> (Value, Block) {
    let lnum = emit_is_number(fb, l);
    let rnum = emit_is_number(fb, r);
    let both_num = fb.ins().band(lnum, rnum);
    let numeric = fb.create_block();
    fb.ins().brif(both_num, numeric, &[], deopt_block, &[]);
    fb.switch_to_block(numeric);

    let lsmi = emit_is_smi(fb, l);
    let rsmi = emit_is_smi(fb, r);
    let both_smi = fb.ins().band(lsmi, rsmi);
    let int_blk = fb.create_block();
    let f64_blk = fb.create_block();
    let done = fb.create_block();
    fb.append_block_param(done, types::I64);
    fb.ins().brif(both_smi, int_blk, &[], f64_blk, &[]);

    // ---- Both SMI: exact integer path. ----
    fb.switch_to_block(int_blk);
    let x = emit_unbox_smi(fb, l);
    let y = emit_unbox_smi(fb, r);
    let x128 = fb.ins().sextend(types::I128, x);
    let y128 = fb.ins().sextend(types::I128, y);
    let wide = match op {
        OP_ADD => fb.ins().iadd(x128, y128),
        OP_SUB => fb.ins().isub(x128, y128),
        _ => fb.ins().imul(x128, y128),
    };
    let (narrowed, _c) = guard_i128_to_i64(fb, deopt_block, wide);
    if op == OP_MUL {
        // A 0 product may actually be -0 (e.g. -1 * 0): box via f64 to keep sign.
        let zbox = fb.create_block();
        let ibox = fb.create_block();
        let is_zero = fb.ins().icmp_imm(IntCC::Equal, narrowed, 0);
        fb.ins().brif(is_zero, zbox, &[], ibox, &[]);
        fb.switch_to_block(zbox);
        let xf = fb.ins().fcvt_from_sint(types::F64, x);
        let yf = fb.ins().fcvt_from_sint(types::F64, y);
        let p = fb.ins().fmul(xf, yf);
        let (b, _d) = emit_box_f64(fb, p);
        fb.ins().jump(done, &[b.into()]);
        fb.switch_to_block(ibox);
        let (b2, _d2) = emit_box_i64(fb, narrowed);
        fb.ins().jump(done, &[b2.into()]);
    } else {
        let (b, _d) = emit_box_i64(fb, narrowed);
        fb.ins().jump(done, &[b.into()]);
    }

    // ---- At least one double (both numeric): f64 path. ----
    fb.switch_to_block(f64_blk);
    let lf = emit_to_f64(fb, l);
    let rf = emit_to_f64(fb, r);
    let f = match op {
        OP_ADD => fb.ins().fadd(lf, rf),
        OP_SUB => fb.ins().fsub(lf, rf),
        _ => fb.ins().fmul(lf, rf),
    };
    let (b, _d) = emit_box_f64(fb, f);
    fb.ins().jump(done, &[b.into()]);

    fb.switch_to_block(done);
    (fb.block_params(done)[0], done)
}

/// Resolve a constant-pool index to a `locals` slot, or `None` to abort.
fn slot_of(kidx_to_slot: &[i32], kidx: u16) -> Option<i32> {
    let k = kidx as usize;
    if k >= kidx_to_slot.len() {
        return None;
    }
    let s = kidx_to_slot[k];
    if s < 0 {
        None
    } else {
        Some(s)
    }
}

fn compile_int_block_impl(
    code: &[u8],
    kidx_to_slot: &[i32],
    boxed: bool,
    prop_sites: &[PropSite],
    get_helper: u64,
    set_helper: u64,
    call_helper: u64,
) -> Option<*const c_void> {
    use std::collections::BTreeSet;

    // ---- Pass 1: validate + decode reach, collect basic-block leaders. ----
    let mut leaders: BTreeSet<usize> = BTreeSet::new();
    leaders.insert(0);
    let mut pc = 0usize;
    while pc < code.len() {
        let op = code[pc];
        let size = int_instr_size(op)?;
        if pc + size > code.len() {
            return None; // truncated
        }
        let next = pc + size;
        match op {
            OP_JMP => {
                let rel = read_i16_le(code, pc + 1) as isize;
                let target = (next as isize + rel) as usize;
                leaders.insert(target);
            }
            OP_JMP_IF_TRUE | OP_JMP_IF_FALSE => {
                let rel = read_i16_le(code, pc + 2) as isize;
                let target = (next as isize + rel) as usize;
                leaders.insert(target);
                leaders.insert(next); // fallthrough
            }
            _ => {}
        }
        if is_terminator(op) {
            leaders.insert(next); // instruction after a terminator starts a block
        }
        pc = next;
    }

    // ---- Build module + signature: fn(*mut i64,*const i64,*mut i64,*mut i32)->i64. ----
    let mut module = make_module()?;
    let ptr_ty = module.target_config().pointer_type();
    let mut ctx = module.make_context();
    let mut sig = module.make_signature();
    sig.params.push(AbiParam::new(ptr_ty)); // regs: *mut i64
    sig.params.push(AbiParam::new(ptr_ty)); // consts: *const i64
    sig.params.push(AbiParam::new(ptr_ty)); // locals: *mut i64
    sig.params.push(AbiParam::new(ptr_ty)); // deopt: *mut i32 (overflow flag)
    sig.returns.push(AbiParam::new(types::I64));
    ctx.func.signature = sig;

    let mut fbctx = FunctionBuilderContext::new();
    {
        let mut fb = FunctionBuilder::new(&mut ctx.func, &mut fbctx);

        // One Cranelift block per leader offset.
        let mut blocks: std::collections::BTreeMap<usize, cranelift_codegen::ir::Block> =
            std::collections::BTreeMap::new();
        for &off in &leaders {
            if off <= code.len() {
                blocks.insert(off, fb.create_block());
            }
        }
        // Dedicated entry block: Cranelift forbids predecessors on the entry
        // block, but offset 0 is a loop back-edge target. So entry just binds the
        // params and jumps into the first instruction block (blocks[&0]).
        let entry = fb.create_block();
        fb.append_block_params_for_function_params(entry);
        fb.switch_to_block(entry);
        let regs = fb.block_params(entry)[0];
        let consts = fb.block_params(entry)[1];
        let locals = fb.block_params(entry)[2];
        let deopt_ptr = fb.block_params(entry)[3];
        fb.ins().jump(blocks[&0], &[]);

        let flags = MemFlags::trusted();

        // Shared deopt trampoline reached when an arithmetic result escapes the
        // f64-exact range: set `*deopt = 1` and return 0 (the value is discarded
        // by the caller, which re-runs the call in the interpreter). `deopt_ptr`
        // is defined in `entry`, which dominates this block, so the use is valid.
        let deopt_block = fb.create_block();
        fb.switch_to_block(deopt_block);
        let one_i32 = fb.ins().iconst(types::I32, 1);
        fb.ins().store(flags, one_i32, deopt_ptr, 0);
        let deopt_ret = fb.ins().iconst(types::I64, 0);
        fb.ins().return_(&[deopt_ret]);
        // Shared exception trampoline reached when a JITed `CALL` throws: the call
        // helper has already set `*deopt = 2`, so just return (do NOT overwrite it
        // like `deopt_block` does — the caller distinguishes 1=deopt from 2=threw).
        let throw_block = fb.create_block();
        fb.switch_to_block(throw_block);
        let throw_ret = fb.ins().iconst(types::I64, 0);
        fb.ins().return_(&[throw_ret]);
        // Helpers to read/write the in-memory register file.
        let load_reg = |fb: &mut FunctionBuilder, r: u8| -> cranelift_codegen::ir::Value {
            fb.ins().load(types::I64, flags, regs, (r as i32) * 8)
        };
        let store_reg = |fb: &mut FunctionBuilder, r: u8, v: cranelift_codegen::ir::Value| {
            fb.ins().store(flags, v, regs, (r as i32) * 8);
        };

        // Signature of the Zig property fast-path callback
        // `fn(recv: u64, key_ptr: [*]const u8, key_len: usize, ic: *anyopaque,
        //     miss: *i32) -> u64`.
        let helper_sig = {
            let mut hs = module.make_signature();
            hs.params.push(AbiParam::new(types::I64)); // recv bits
            hs.params.push(AbiParam::new(ptr_ty)); // key ptr
            hs.params.push(AbiParam::new(types::I64)); // key len
            hs.params.push(AbiParam::new(ptr_ty)); // ic ptr
            hs.params.push(AbiParam::new(ptr_ty)); // miss ptr (*i32)
            hs.returns.push(AbiParam::new(types::I64)); // value bits
            fb.import_signature(hs)
        };
        // Signature of the Zig property STORE callback
        // `fn(recv: u64, key_ptr, key_len: usize, ic: *anyopaque, val: u64,
        //     miss: *i32) -> void`.
        let set_sig = {
            let mut ss = module.make_signature();
            ss.params.push(AbiParam::new(types::I64)); // recv bits
            ss.params.push(AbiParam::new(ptr_ty)); // key ptr
            ss.params.push(AbiParam::new(types::I64)); // key len
            ss.params.push(AbiParam::new(ptr_ty)); // ic ptr
            ss.params.push(AbiParam::new(types::I64)); // value bits
            ss.params.push(AbiParam::new(ptr_ty)); // miss ptr (*i32)
            fb.import_signature(ss)
        };
        // Signature of the Zig CALL trampoline
        // `fn(regs: [*]i64, base: u32, nargs: u32, ret_dst: u32, deopt: *i32)`.
        // It reads callee/args from `regs`, re-enters the interpreter, writes the
        // result to regs[ret_dst], and sets *deopt (0 = ok, 2 = the callee threw).
        let call_sig = {
            let mut cs = module.make_signature();
            cs.params.push(AbiParam::new(ptr_ty)); // regs ptr
            cs.params.push(AbiParam::new(types::I32)); // base
            cs.params.push(AbiParam::new(types::I32)); // nargs
            cs.params.push(AbiParam::new(types::I32)); // ret_dst
            cs.params.push(AbiParam::new(ptr_ty)); // deopt ptr
            fb.import_signature(cs)
        };

        let mut cur = entry;
        let mut terminated = true; // entry already ends in a jump to blocks[&0]
        let mut pc = 0usize;
        while pc < code.len() {
            // Entering a new basic block?
            if let Some(&blk) = blocks.get(&pc) {
                if blk != cur {
                    if !terminated {
                        fb.ins().jump(blk, &[]); // fallthrough edge
                    }
                    fb.switch_to_block(blk);
                    cur = blk;
                    terminated = false;
                }
            }
            let op = code[pc];
            let size = int_instr_size(op)?;
            let next = pc + size;
            match op {
                OP_LOAD_K => {
                    let rdst = code[pc + 1];
                    let kidx = read_u16_le(code, pc + 2);
                    let v = fb.ins().load(types::I64, flags, consts, (kidx as i32) * 8);
                    store_reg(&mut fb, rdst, v);
                }
                OP_LOAD_TRUE => {
                    // Boxed mode stores the NaN-box immediate; int mode a raw 1.
                    let t = fb.ins().iconst(types::I64, if boxed { NB_TRUE } else { 1 });
                    store_reg(&mut fb, code[pc + 1], t);
                }
                OP_LOAD_FALSE => {
                    let f = fb.ins().iconst(types::I64, if boxed { NB_FALSE } else { 0 });
                    store_reg(&mut fb, code[pc + 1], f);
                }
                OP_LOAD_UNDEF => {
                    // Monomorphic-int model: undefined is 0. Sound only because the
                    // caller restricts JITing to functions that assign every local
                    // before reading it (the hoist/init prologue is overwritten).
                    let z = fb.ins().iconst(types::I64, 0);
                    store_reg(&mut fb, code[pc + 1], z);
                }
                OP_MOVE => {
                    let v = load_reg(&mut fb, code[pc + 2]);
                    store_reg(&mut fb, code[pc + 1], v);
                }
                OP_GET_GLOBAL => {
                    let rdst = code[pc + 1];
                    let kidx = read_u16_le(code, pc + 2);
                    let slot = slot_of(kidx_to_slot, kidx)?; // non-local -> bail
                    let v = fb.ins().load(types::I64, flags, locals, slot * 8);
                    store_reg(&mut fb, rdst, v);
                }
                OP_SET_GLOBAL | OP_DEFINE_GLOBAL => {
                    // Encoding: op, Kname u16-LE, Rsrc u8.
                    let kidx = read_u16_le(code, pc + 1);
                    let rsrc = code[pc + 3];
                    let slot = slot_of(kidx_to_slot, kidx)?; // non-local -> bail
                    let v = load_reg(&mut fb, rsrc);
                    fb.ins().store(flags, v, locals, slot * 8);
                }
                OP_HOIST_VAR => {
                    // op, Kname u16-LE. Locals are pre-zeroed by the caller; no-op.
                }
                OP_ADD | OP_SUB | OP_MUL => {
                    let l = load_reg(&mut fb, code[pc + 2]);
                    let r = load_reg(&mut fb, code[pc + 3]);
                    if boxed {
                        // Guard both numeric (else deopt); SMI→exact i128 path,
                        // else f64; re-box (makeNumber), preserving -0 on MUL.
                        let (res, done) = emit_boxed_num_binop(&mut fb, deopt_block, l, r, op);
                        cur = done;
                        store_reg(&mut fb, code[pc + 1], res);
                    } else {
                        // Unboxed i64: sign-extend so the op cannot wrap, guard 2^53.
                        let l128 = fb.ins().sextend(types::I128, l);
                        let r128 = fb.ins().sextend(types::I128, r);
                        let wide = match op {
                            OP_ADD => fb.ins().iadd(l128, r128),
                            OP_SUB => fb.ins().isub(l128, r128),
                            _ => fb.ins().imul(l128, r128),
                        };
                        let (res, cont) = guard_i128_to_i64(&mut fb, deopt_block, wide);
                        cur = cont;
                        store_reg(&mut fb, code[pc + 1], res);
                    }
                }
                OP_INC | OP_DEC => {
                    let v = load_reg(&mut fb, code[pc + 2]);
                    if boxed {
                        // Guard SMI (else deopt), ±1 in i128 + 2^53 guard, re-box.
                        let is = emit_is_smi(&mut fb, v);
                        let ok = fb.create_block();
                        fb.ins().brif(is, ok, &[], deopt_block, &[]);
                        fb.switch_to_block(ok);
                        let x = emit_unbox_smi(&mut fb, v);
                        let x128 = fb.ins().sextend(types::I128, x);
                        let one64 = fb.ins().iconst(types::I64, 1);
                        let one = fb.ins().sextend(types::I128, one64);
                        let wide = if op == OP_INC {
                            fb.ins().iadd(x128, one)
                        } else {
                            fb.ins().isub(x128, one)
                        };
                        let (narrowed, _c) = guard_i128_to_i64(&mut fb, deopt_block, wide);
                        let (res, done) = emit_box_i64(&mut fb, narrowed);
                        cur = done;
                        store_reg(&mut fb, code[pc + 1], res);
                    } else {
                        let v128 = fb.ins().sextend(types::I128, v);
                        let one64 = fb.ins().iconst(types::I64, 1);
                        let one = fb.ins().sextend(types::I128, one64);
                        let wide = if op == OP_INC {
                            fb.ins().iadd(v128, one)
                        } else {
                            fb.ins().isub(v128, one)
                        };
                        let (res, cont) = guard_i128_to_i64(&mut fb, deopt_block, wide);
                        cur = cont;
                        store_reg(&mut fb, code[pc + 1], res);
                    }
                }
                OP_NOT => {
                    let v = load_reg(&mut fb, code[pc + 2]);
                    if boxed {
                        // Guard SMI (else deopt); result is a raw 0/1 consumed by the
                        // immediately-following conditional jump (never re-boxed).
                        let is = emit_is_smi(&mut fb, v);
                        let ok = fb.create_block();
                        fb.ins().brif(is, ok, &[], deopt_block, &[]);
                        fb.switch_to_block(ok);
                        cur = ok;
                        let x = emit_unbox_smi(&mut fb, v);
                        let c = fb.ins().icmp_imm(IntCC::Equal, x, 0);
                        let r = fb.ins().uextend(types::I64, c);
                        store_reg(&mut fb, code[pc + 1], r);
                    } else {
                        let c = fb.ins().icmp_imm(IntCC::Equal, v, 0);
                        let r = fb.ins().uextend(types::I64, c);
                        store_reg(&mut fb, code[pc + 1], r);
                    }
                }
                OP_EQ | OP_NEQ | OP_SEQ | OP_SNEQ | OP_LT | OP_LE | OP_GT | OP_GE => {
                    let l = load_reg(&mut fb, code[pc + 2]);
                    let r = load_reg(&mut fb, code[pc + 3]);
                    let cc = match op {
                        OP_EQ | OP_SEQ => IntCC::Equal,
                        OP_NEQ | OP_SNEQ => IntCC::NotEqual,
                        OP_LT => IntCC::SignedLessThan,
                        OP_LE => IntCC::SignedLessThanOrEqual,
                        OP_GT => IntCC::SignedGreaterThan,
                        _ => IntCC::SignedGreaterThanOrEqual,
                    };
                    let (lv, rv) = if boxed {
                        // Guard both SMI (else deopt), then compare unboxed payloads.
                        let lsmi = emit_is_smi(&mut fb, l);
                        let rsmi = emit_is_smi(&mut fb, r);
                        let both = fb.ins().band(lsmi, rsmi);
                        let ok = fb.create_block();
                        fb.ins().brif(both, ok, &[], deopt_block, &[]);
                        fb.switch_to_block(ok);
                        cur = ok;
                        (emit_unbox_smi(&mut fb, l), emit_unbox_smi(&mut fb, r))
                    } else {
                        (l, r)
                    };
                    let c = fb.ins().icmp(cc, lv, rv);
                    let res = fb.ins().uextend(types::I64, c);
                    store_reg(&mut fb, code[pc + 1], res);
                }
                OP_JMP => {
                    let rel = read_i16_le(code, pc + 1) as isize;
                    let target = (next as isize + rel) as usize;
                    let blk = *blocks.get(&target)?;
                    fb.ins().jump(blk, &[]);
                    terminated = true;
                }
                OP_JMP_IF_TRUE | OP_JMP_IF_FALSE => {
                    let rcond = code[pc + 1];
                    let rel = read_i16_le(code, pc + 2) as isize;
                    let target = (next as isize + rel) as usize;
                    let tblk = *blocks.get(&target)?;
                    let fblk = *blocks.get(&next)?;
                    let cval = load_reg(&mut fb, rcond);
                    let is_true = fb.ins().icmp_imm(IntCC::NotEqual, cval, 0);
                    if op == OP_JMP_IF_TRUE {
                        fb.ins().brif(is_true, tblk, &[], fblk, &[]);
                    } else {
                        // JMP_IF_FALSE: jump to target when condition is false.
                        fb.ins().brif(is_true, fblk, &[], tblk, &[]);
                    }
                    terminated = true;
                }
                OP_GET_PROP => {
                    // Boxed tier S3: monomorphic own-data property read. Calls the
                    // Zig fast-path helper with the baked (shape, slot); the helper
                    // sets *deopt on a miss (non-object / wrong shape / accessor /
                    // proto prop) and the region deopts to the interpreter.
                    if !boxed {
                        return None;
                    }
                    let rdst = code[pc + 1];
                    let robj = code[pc + 2];
                    let site = prop_sites.iter().find(|s| s.pc as usize == pc)?;
                    let recv = load_reg(&mut fb, robj);
                    let key_p = fb.ins().iconst(ptr_ty, site.key_ptr as i64);
                    let key_l = fb.ins().iconst(types::I64, site.key_len as i64);
                    let ic_p = fb.ins().iconst(ptr_ty, site.ic_ptr as i64);
                    let callee = fb.ins().iconst(ptr_ty, get_helper as i64);
                    let call = fb.ins().call_indirect(
                        helper_sig,
                        callee,
                        &[recv, key_p, key_l, ic_p, deopt_ptr],
                    );
                    let result = fb.inst_results(call)[0];
                    let missed = fb.ins().load(types::I32, flags, deopt_ptr, 0);
                    let cont = fb.create_block();
                    fb.ins().brif(missed, deopt_block, &[], cont, &[]);
                    fb.switch_to_block(cont);
                    cur = cont;
                    store_reg(&mut fb, rdst, result);
                }
                OP_SET_PROP => {
                    // Boxed tier S3e: own-data property store via the Zig helper.
                    // The helper sets *deopt on a miss (accessor / read-only / new
                    // prop / wrong shape / non-object) BEFORE storing, so a miss has
                    // no side effect; the analyzer guarantees no fallible op runs
                    // after a successful store, so coarse deopt stays sound.
                    if !boxed {
                        return None;
                    }
                    let robj = code[pc + 1];
                    let rval = code[pc + 4];
                    let site = prop_sites.iter().find(|s| s.pc as usize == pc)?;
                    let recv = load_reg(&mut fb, robj);
                    let val = load_reg(&mut fb, rval);
                    let key_p = fb.ins().iconst(ptr_ty, site.key_ptr as i64);
                    let key_l = fb.ins().iconst(types::I64, site.key_len as i64);
                    let ic_p = fb.ins().iconst(ptr_ty, site.ic_ptr as i64);
                    let callee = fb.ins().iconst(ptr_ty, set_helper as i64);
                    fb.ins().call_indirect(
                        set_sig,
                        callee,
                        &[recv, key_p, key_l, ic_p, val, deopt_ptr],
                    );
                    let missed = fb.ins().load(types::I32, flags, deopt_ptr, 0);
                    let cont = fb.create_block();
                    fb.ins().brif(missed, deopt_block, &[], cont, &[]);
                    fb.switch_to_block(cont);
                    cur = cont;
                }
                OP_CALL => {
                    // Boxed tier S4: re-enter the interpreter for a call. The Zig
                    // trampoline reads callee/args from the register file, runs the
                    // call, writes the result into regs[ret_dst], and sets *deopt = 2
                    // if the callee threw — in which case we return via `throw_block`
                    // (preserving the 2) so the caller propagates the exception
                    // WITHOUT re-running the region (the call's side effects already
                    // happened — the interpreter would have done the same).
                    if !boxed {
                        return None;
                    }
                    let base = fb.ins().iconst(types::I32, code[pc + 1] as i64);
                    let nargs = fb.ins().iconst(types::I32, code[pc + 2] as i64);
                    let ret_dst = fb.ins().iconst(types::I32, code[pc + 3] as i64);
                    let callee = fb.ins().iconst(ptr_ty, call_helper as i64);
                    fb.ins().call_indirect(
                        call_sig,
                        callee,
                        &[regs, base, nargs, ret_dst, deopt_ptr],
                    );
                    let threw = fb.ins().load(types::I32, flags, deopt_ptr, 0);
                    let cont = fb.create_block();
                    fb.ins().brif(threw, throw_block, &[], cont, &[]);
                    fb.switch_to_block(cont);
                    cur = cont;
                }
                OP_RETURN => {
                    let v = load_reg(&mut fb, code[pc + 1]);
                    fb.ins().return_(&[v]);
                    terminated = true;
                }
                OP_RETURN_UNDEF | OP_HALT => {
                    let z = fb.ins().iconst(types::I64, 0);
                    fb.ins().return_(&[z]);
                    terminated = true;
                }
                _ => return None,
            }
            pc = next;
        }
        // Fall off the end without a terminator: return 0.
        if !terminated {
            let z = fb.ins().iconst(types::I64, 0);
            fb.ins().return_(&[z]);
        }

        fb.seal_all_blocks();
        fb.finalize();
    }

    let id = module
        .declare_function("jsz_int_block", Linkage::Export, &ctx.func.signature)
        .ok()?;
    module.define_function(id, &mut ctx).ok()?;
    module.clear_context(&mut ctx);
    module.finalize_definitions().ok()?;
    let code_ptr = module.get_finalized_function(id);
    std::mem::forget(module);
    Some(code_ptr as *const c_void)
}

/// Phase 9 — native accumulator loop (loop *body* compiled, not just elided).
///
/// Compile `fn(start: i64, limit: i64, step: i64, s_init: f64, out_i: *mut i64) -> f64`
/// implementing `i = start; s = s_init; while (i < limit) { s += (f64)i; i += step; }
/// *out_i = i; return s;` — the canonical summation loop with an unboxed i64
/// induction var and an unboxed f64 accumulator. The IR carries both `i` and
/// `s` as loop block params; the body emits `fcvt_from_sint` + `fadd` (the
/// translated `s = s + i`) and `iadd` (the step), then the back-edge `jump`.
/// Only the `<` / `+` shape is native; other comparisons/ops use the Zig kernel.
/// Returns null on codegen failure.
#[unsafe(no_mangle)]
pub extern "C" fn jsz_clif_compile_accumulate_loop() -> *const c_void {
    let Some(mut module) = make_module() else {
        return std::ptr::null();
    };
    let ptr_ty = module.target_config().pointer_type();

    let mut ctx = module.make_context();
    let mut sig = module.make_signature();
    sig.params.push(AbiParam::new(types::I64)); // start
    sig.params.push(AbiParam::new(types::I64)); // limit
    sig.params.push(AbiParam::new(types::I64)); // step
    sig.params.push(AbiParam::new(types::F64)); // s_init
    sig.params.push(AbiParam::new(ptr_ty)); // out_i: *mut i64
    sig.returns.push(AbiParam::new(types::F64)); // final s
    ctx.func.signature = sig;

    let mut fbctx = FunctionBuilderContext::new();
    {
        let mut fb = FunctionBuilder::new(&mut ctx.func, &mut fbctx);
        let entry = fb.create_block();
        let header = fb.create_block();
        let body = fb.create_block();
        let exit = fb.create_block();
        fb.append_block_params_for_function_params(entry);
        // Loop-carried (i: i64, s: f64).
        fb.append_block_param(header, types::I64);
        fb.append_block_param(header, types::F64);
        fb.append_block_param(body, types::I64);
        fb.append_block_param(body, types::F64);
        fb.append_block_param(exit, types::I64);
        fb.append_block_param(exit, types::F64);

        fb.switch_to_block(entry);
        let start = fb.block_params(entry)[0];
        let limit = fb.block_params(entry)[1];
        let step = fb.block_params(entry)[2];
        let s_init = fb.block_params(entry)[3];
        let out_i = fb.block_params(entry)[4];
        fb.ins().jump(header, &[start.into(), s_init.into()]);

        // header(i,s): if i < limit -> body(i,s) else exit(i,s)
        fb.switch_to_block(header);
        let i_hdr = fb.block_params(header)[0];
        let s_hdr = fb.block_params(header)[1];
        let cond = fb.ins().icmp(IntCC::SignedLessThan, i_hdr, limit);
        fb.ins().brif(
            cond,
            body,
            &[i_hdr.into(), s_hdr.into()],
            exit,
            &[i_hdr.into(), s_hdr.into()],
        );

        // body(i,s): s2 = s + (f64)i; i2 = i + step; jump header(i2,s2)  <- back-edge
        fb.switch_to_block(body);
        let i_body = fb.block_params(body)[0];
        let s_body = fb.block_params(body)[1];
        let i_f = fb.ins().fcvt_from_sint(types::F64, i_body);
        let s_next = fb.ins().fadd(s_body, i_f);
        let i_next = fb.ins().iadd(i_body, step);
        fb.ins().jump(header, &[i_next.into(), s_next.into()]);

        // exit(i,s): *out_i = i; return s
        fb.switch_to_block(exit);
        let i_exit = fb.block_params(exit)[0];
        let s_exit = fb.block_params(exit)[1];
        fb.ins().store(MemFlags::trusted(), i_exit, out_i, 0);
        fb.ins().return_(&[s_exit]);

        fb.seal_block(entry);
        fb.seal_block(header);
        fb.seal_block(body);
        fb.seal_block(exit);
        fb.finalize();
    }

    let id =
        match module.declare_function("jsz_accumulate_loop", Linkage::Export, &ctx.func.signature) {
            Ok(id) => id,
            Err(_) => return std::ptr::null(),
        };
    if module.define_function(id, &mut ctx).is_err() {
        return std::ptr::null();
    }
    module.clear_context(&mut ctx);
    if module.finalize_definitions().is_err() {
        return std::ptr::null();
    }
    let code = module.get_finalized_function(id);
    std::mem::forget(module);
    code as *const c_void
}
