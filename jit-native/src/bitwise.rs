use cranelift_codegen::ir::{Block, InstBuilder, MemFlags, Value, types};
use cranelift_frontend::FunctionBuilder;

use super::{emit_box_i64, emit_is_smi, emit_unbox_smi};

pub(crate) const OP_BIT_AND: u8 = 16;
pub(crate) const OP_BIT_OR: u8 = 17;
pub(crate) const OP_BIT_XOR: u8 = 18;
pub(crate) const OP_SHL: u8 = 19;
pub(crate) const OP_SHR: u8 = 20;
pub(crate) const OP_USHR: u8 = 21;
pub(crate) const OP_BIT_NOT: u8 = 23;

#[derive(Clone, Copy)]
enum BinaryOp {
    And,
    Or,
    Xor,
    ShiftLeft,
    ShiftRight,
    ShiftRightUnsigned,
}

impl BinaryOp {
    const fn parse(op: u8) -> Option<Self> {
        match op {
            OP_BIT_AND => Some(Self::And),
            OP_BIT_OR => Some(Self::Or),
            OP_BIT_XOR => Some(Self::Xor),
            OP_SHL => Some(Self::ShiftLeft),
            OP_SHR => Some(Self::ShiftRight),
            OP_USHR => Some(Self::ShiftRightUnsigned),
            _ => None,
        }
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
    if BinaryOp::parse(op).is_some() {
        Some(4)
    } else if op == OP_BIT_NOT {
        Some(3)
    } else {
        None
    }
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

fn emit_raw_binary(fb: &mut FunctionBuilder, op: BinaryOp, lhs: Value, rhs: Value) -> Value {
    let lhs32 = fb.ins().ireduce(types::I32, lhs);
    let rhs32 = fb.ins().ireduce(types::I32, rhs);
    let result32 = match op {
        BinaryOp::And => fb.ins().band(lhs32, rhs32),
        BinaryOp::Or => fb.ins().bor(lhs32, rhs32),
        BinaryOp::Xor => fb.ins().bxor(lhs32, rhs32),
        BinaryOp::ShiftLeft => {
            let count = fb.ins().band_imm(rhs32, 31);
            fb.ins().ishl(lhs32, count)
        }
        BinaryOp::ShiftRight => {
            let count = fb.ins().band_imm(rhs32, 31);
            fb.ins().sshr(lhs32, count)
        }
        BinaryOp::ShiftRightUnsigned => {
            let count = fb.ins().band_imm(rhs32, 31);
            fb.ins().ushr(lhs32, count)
        }
    };
    match op {
        BinaryOp::ShiftRightUnsigned => fb.ins().uextend(types::I64, result32),
        BinaryOp::And
        | BinaryOp::Or
        | BinaryOp::Xor
        | BinaryOp::ShiftLeft
        | BinaryOp::ShiftRight => fb.ins().sextend(types::I64, result32),
    }
}

fn emit_not(fb: &mut FunctionBuilder, request: &EmitRequest<'_>, operand: Value) -> Block {
    let active = if request.boxed {
        let is_smi = emit_is_smi(fb, operand);
        let native_block = fb.create_block();
        let pc_value = fb.ins().iconst(types::I32, request.pc as i64);
        fb.ins().brif(
            is_smi,
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
    let raw = if request.boxed {
        emit_unbox_smi(fb, operand)
    } else {
        operand
    };
    let raw32 = fb.ins().ireduce(types::I32, raw);
    let inverted32 = fb.ins().bxor_imm(raw32, -1);
    let inverted = fb.ins().sextend(types::I64, inverted32);
    if request.boxed {
        let (boxed, done) = emit_box_i64(fb, inverted);
        store_reg(fb, request, request.code[request.pc + 1], boxed);
        done
    } else {
        store_reg(fb, request, request.code[request.pc + 1], inverted);
        active
    }
}

pub(crate) fn emit(fb: &mut FunctionBuilder, request: EmitRequest<'_>) -> Block {
    let op = request.code[request.pc];
    let lhs = load_reg(fb, &request, request.code[request.pc + 2]);
    if op == OP_BIT_NOT {
        return emit_not(fb, &request, lhs);
    }
    let Some(binary_op) = BinaryOp::parse(op) else {
        return request.current_block;
    };
    let rhs = load_reg(fb, &request, request.code[request.pc + 3]);
    if request.boxed {
        let lhs_smi = emit_is_smi(fb, lhs);
        let rhs_smi = emit_is_smi(fb, rhs);
        let both_smi = fb.ins().band(lhs_smi, rhs_smi);
        let native_block = fb.create_block();
        let pc_value = fb.ins().iconst(types::I32, request.pc as i64);
        fb.ins().brif(
            both_smi,
            native_block,
            &[],
            request.fine_deopt_block,
            &[pc_value.into()],
        );
        fb.switch_to_block(native_block);
        let raw_lhs = emit_unbox_smi(fb, lhs);
        let raw_rhs = emit_unbox_smi(fb, rhs);
        let raw = emit_raw_binary(fb, binary_op, raw_lhs, raw_rhs);
        let (boxed, done) = emit_box_i64(fb, raw);
        store_reg(fb, &request, request.code[request.pc + 1], boxed);
        return done;
    }

    let raw = emit_raw_binary(fb, binary_op, lhs, rhs);
    store_reg(fb, &request, request.code[request.pc + 1], raw);
    request.current_block
}
