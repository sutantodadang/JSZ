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

use cranelift_codegen::ir::{types, AbiParam, InstBuilder};
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

/// Probe that the native backend is linked. Always returns 1 when present.
#[unsafe(no_mangle)]
pub extern "C" fn jsz_clif_available() -> i32 {
    1
}
