use cranelift_codegen::ir::{Block, InstBuilder, MemFlags, Value, types};
use cranelift_codegen::ir::condcodes::IntCC;
use cranelift_frontend::FunctionBuilder;

use super::{emit_box_f64, emit_box_i64, emit_is_number, emit_is_smi, emit_to_f64, emit_unbox_smi};

pub(crate) const OP_TO_NUMERIC: u8 = 89;
pub(crate) const OP_DIV: u8 = 13;
pub(crate) const OP_MOD: u8 = 14;
pub(crate) const OP_NEG: u8 = 22;

/// Ops legal ONLY in the boxed lane (results may be non-integer / -0).
pub(crate) const fn boxed_instr_size(op: u8) -> Option<usize> {
    match op {
        OP_DIV | OP_MOD => Some(4),
        OP_NEG => Some(3),
        _ => None,
    }
}

pub(crate) struct EmitRequest<'a> {
    pub code: &'a [u8],
    pub pc: usize,
    pub boxed: bool,
    pub current_block: Block,
    pub fine_deopt_block: Block,
    pub flags: MemFlags,
    pub regs: Value,
}

pub(crate) const fn instr_size(op: u8) -> Option<usize> {
    if op == OP_TO_NUMERIC { Some(3) } else { None }
}

fn load_reg(fb: &mut FunctionBuilder, request: &EmitRequest<'_>, register: u8) -> Value {
    fb.ins().load(
        types::I64,
        request.flags,
        request.regs,
        i32::from(register) * 8,
    )
}

fn store_reg(fb: &mut FunctionBuilder, request: &EmitRequest<'_>, register: u8, value: Value) {
    fb.ins()
        .store(request.flags, value, request.regs, i32::from(register) * 8);
}

fn emit_to_numeric(fb: &mut FunctionBuilder, request: &EmitRequest<'_>) -> Block {
    let source = request.code[request.pc + 2];
    let value = load_reg(fb, request, source);
    let active = if request.boxed {
        let is_number = emit_is_number(fb, value);
        let native_block = fb.create_block();
        let pc_value = fb.ins().iconst(types::I32, request.pc as i64);
        fb.ins().brif(
            is_number,
            native_block,
            &[],
            request.fine_deopt_block,
            &[pc_value.into()],
        );
        fb.switch_to_block(native_block);
        native_block
    } else {
        request.current_block
    };
    let destination = request.code[request.pc + 1];
    store_reg(fb, request, destination, value);
    active
}

/// `a / b` (boxed only): guard both numeric, compute in f64 (IEEE division IS JS
/// division — ±Infinity/NaN fall out for free), re-box via `makeNumber`
/// (canonicalizes an integral quotient to SMI).
fn emit_div(fb: &mut FunctionBuilder, request: &EmitRequest<'_>) -> Block {
    let lhs = load_reg(fb, request, request.code[request.pc + 2]);
    let rhs = load_reg(fb, request, request.code[request.pc + 3]);
    let lhs_num = emit_is_number(fb, lhs);
    let rhs_num = emit_is_number(fb, rhs);
    let both = fb.ins().band(lhs_num, rhs_num);
    let native_block = fb.create_block();
    let pc_value = fb.ins().iconst(types::I32, request.pc as i64);
    fb.ins().brif(
        both,
        native_block,
        &[],
        request.fine_deopt_block,
        &[pc_value.into()],
    );
    fb.switch_to_block(native_block);
    let lf = emit_to_f64(fb, lhs);
    let rf = emit_to_f64(fb, rhs);
    let q = fb.ins().fdiv(lf, rf);
    let (boxed_val, done) = emit_box_f64(fb, q);
    fb.switch_to_block(done);
    store_reg(fb, request, request.code[request.pc + 1], boxed_val);
    done
}

/// `-a` (boxed only): guard numeric, negate in f64 (handles -0, i32::MIN, and
/// doubles exactly), re-box via `makeNumber`.
fn emit_neg(fb: &mut FunctionBuilder, request: &EmitRequest<'_>) -> Block {
    let src = load_reg(fb, request, request.code[request.pc + 2]);
    let is_number = emit_is_number(fb, src);
    let native_block = fb.create_block();
    let pc_value = fb.ins().iconst(types::I32, request.pc as i64);
    fb.ins().brif(
        is_number,
        native_block,
        &[],
        request.fine_deopt_block,
        &[pc_value.into()],
    );
    fb.switch_to_block(native_block);
    let f = emit_to_f64(fb, src);
    let n = fb.ins().fneg(f);
    let (boxed_val, done) = emit_box_f64(fb, n);
    fb.switch_to_block(done);
    store_reg(fb, request, request.code[request.pc + 1], boxed_val);
    done
}

/// `a % b` (boxed only): guard both numeric, then both SMI with a non-zero
/// divisor (else fine-deopt to the interpreter — doubles and `%0` are rare and
/// simply run slower there). Truncated `srem` on the sign-extended i32 payloads
/// matches JS `%` (sign follows the dividend) exactly; i64::MIN/-1 traps are
/// impossible because payloads are 32-bit. Re-derive `-0` explicitly (`-6 % 3`
/// is `-0` in JS, but `srem` alone yields plain `0`).
fn emit_mod(fb: &mut FunctionBuilder, request: &EmitRequest<'_>) -> Block {
    let lhs = load_reg(fb, request, request.code[request.pc + 2]);
    let rhs = load_reg(fb, request, request.code[request.pc + 3]);
    let lhs_num = emit_is_number(fb, lhs);
    let rhs_num = emit_is_number(fb, rhs);
    let both_num = fb.ins().band(lhs_num, rhs_num);
    let smi_block = fb.create_block();
    let pc_value = fb.ins().iconst(types::I32, request.pc as i64);
    fb.ins().brif(
        both_num,
        smi_block,
        &[],
        request.fine_deopt_block,
        &[pc_value.into()],
    );
    fb.switch_to_block(smi_block);

    let lhs_smi = emit_is_smi(fb, lhs);
    let rhs_smi = emit_is_smi(fb, rhs);
    let both_smi = fb.ins().band(lhs_smi, rhs_smi);
    let rhs_raw = emit_unbox_smi(fb, rhs);
    let rhs_nonzero = fb.ins().icmp_imm(IntCC::NotEqual, rhs_raw, 0);
    let ok = fb.ins().band(both_smi, rhs_nonzero);
    let compute_block = fb.create_block();
    fb.ins().brif(
        ok,
        compute_block,
        &[],
        request.fine_deopt_block,
        &[pc_value.into()],
    );
    fb.switch_to_block(compute_block);

    let l_raw = emit_unbox_smi(fb, lhs);
    let rem = fb.ins().srem(l_raw, rhs_raw);
    let rem_zero = fb.ins().icmp_imm(IntCC::Equal, rem, 0);
    let lhs_neg = fb.ins().icmp_imm(IntCC::SignedLessThan, l_raw, 0);
    let needs_neg_zero = fb.ins().band(rem_zero, lhs_neg);

    let neg_zero_block = fb.create_block();
    let int_block = fb.create_block();
    let done = fb.create_block();
    fb.append_block_param(done, types::I64);
    fb.ins()
        .brif(needs_neg_zero, neg_zero_block, &[], int_block, &[]);

    fb.switch_to_block(neg_zero_block);
    let neg_zero_f = fb.ins().f64const(-0.0);
    let (nz_boxed, nz_done) = emit_box_f64(fb, neg_zero_f);
    fb.switch_to_block(nz_done);
    fb.ins().jump(done, &[nz_boxed.into()]);

    fb.switch_to_block(int_block);
    let (int_boxed, int_done) = emit_box_i64(fb, rem);
    fb.switch_to_block(int_done);
    fb.ins().jump(done, &[int_boxed.into()]);

    fb.switch_to_block(done);
    let result = fb.block_params(done)[0];
    store_reg(fb, request, request.code[request.pc + 1], result);
    done
}

pub(crate) fn emit(fb: &mut FunctionBuilder, request: EmitRequest<'_>) -> Block {
    let op = request.code[request.pc];
    if !request.boxed {
        // DIV/MOD/NEG are boxed-lane-only; unreachable by construction since
        // `boxed_instr_size` (the only sizer that admits them) is never
        // consulted in the non-boxed lane.
        return match op {
            OP_DIV | OP_MOD | OP_NEG => request.current_block,
            _ => emit_to_numeric(fb, &request),
        };
    }
    match op {
        OP_DIV => emit_div(fb, &request),
        OP_MOD => emit_mod(fb, &request),
        OP_NEG => emit_neg(fb, &request),
        _ => emit_to_numeric(fb, &request),
    }
}
