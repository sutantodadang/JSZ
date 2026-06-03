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
