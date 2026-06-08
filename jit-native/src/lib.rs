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

use cranelift_codegen::ir::condcodes::IntCC;
use cranelift_codegen::ir::{types, AbiParam, InstBuilder, MemFlags};
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
const OP_JMP: u8 = 36;
const OP_JMP_IF_TRUE: u8 = 37;
const OP_JMP_IF_FALSE: u8 = 38;
const OP_RETURN: u8 = 45;
const OP_RETURN_UNDEF: u8 = 46;
const OP_HALT: u8 = 47;

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
/// Returns `fn(regs: *mut i64, consts: *const i64, locals: *mut i64) -> i64`
/// (the RETURNed value), or null if the bytecode uses an unsupported opcode or
/// references a non-local name.
///
/// `kidx_to_slot[k]` maps a constant-pool index `k` (the name operand of
/// `GET_GLOBAL`/`SET_GLOBAL`/`DEFINE_GLOBAL`) to a dense `locals` slot, or a
/// negative value when that name is NOT a monomorphic-int function local (a true
/// global, a closure-captured var, etc.) — any such access aborts compilation so
/// the caller keeps interpreting. `locals` holds the unboxed-i64 function-local
/// variables; the caller marshals them in and out around the call.
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
    compile_int_block_impl(code, slots).unwrap_or(std::ptr::null())
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

fn compile_int_block_impl(code: &[u8], kidx_to_slot: &[i32]) -> Option<*const c_void> {
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

    // ---- Build the module + signature: fn(*mut i64, *const i64) -> i64. ----
    let mut module = make_module()?;
    let ptr_ty = module.target_config().pointer_type();
    let mut ctx = module.make_context();
    let mut sig = module.make_signature();
    sig.params.push(AbiParam::new(ptr_ty)); // regs: *mut i64
    sig.params.push(AbiParam::new(ptr_ty)); // consts: *const i64
    sig.params.push(AbiParam::new(ptr_ty)); // locals: *mut i64
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
        fb.ins().jump(blocks[&0], &[]);

        let flags = MemFlags::trusted();
        // Helpers to read/write the in-memory register file.
        let load_reg = |fb: &mut FunctionBuilder, r: u8| -> cranelift_codegen::ir::Value {
            fb.ins().load(types::I64, flags, regs, (r as i32) * 8)
        };
        let store_reg = |fb: &mut FunctionBuilder, r: u8, v: cranelift_codegen::ir::Value| {
            fb.ins().store(flags, v, regs, (r as i32) * 8);
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
                    let one = fb.ins().iconst(types::I64, 1);
                    store_reg(&mut fb, code[pc + 1], one);
                }
                OP_LOAD_FALSE => {
                    let zero = fb.ins().iconst(types::I64, 0);
                    store_reg(&mut fb, code[pc + 1], zero);
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
                    let res = match op {
                        OP_ADD => fb.ins().iadd(l, r),
                        OP_SUB => fb.ins().isub(l, r),
                        _ => fb.ins().imul(l, r),
                    };
                    store_reg(&mut fb, code[pc + 1], res);
                }
                OP_INC | OP_DEC => {
                    let v = load_reg(&mut fb, code[pc + 2]);
                    let res = if op == OP_INC {
                        fb.ins().iadd_imm(v, 1)
                    } else {
                        fb.ins().iadd_imm(v, -1)
                    };
                    store_reg(&mut fb, code[pc + 1], res);
                }
                OP_NOT => {
                    let v = load_reg(&mut fb, code[pc + 2]);
                    let c = fb.ins().icmp_imm(IntCC::Equal, v, 0);
                    let r = fb.ins().uextend(types::I64, c);
                    store_reg(&mut fb, code[pc + 1], r);
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
                    let c = fb.ins().icmp(cc, l, r);
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
