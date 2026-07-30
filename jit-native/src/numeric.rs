use cranelift_codegen::ir::{Block, InstBuilder, MemFlags, Value, types};
use cranelift_frontend::FunctionBuilder;

use super::emit_is_number;

pub(crate) const OP_TO_NUMERIC: u8 = 89;

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

pub(crate) fn emit(fb: &mut FunctionBuilder, request: EmitRequest<'_>) -> Block {
    let source = request.code[request.pc + 2];
    let value = fb.ins().load(
        types::I64,
        request.flags,
        request.regs,
        i32::from(source) * 8,
    );
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
    fb.ins().store(
        request.flags,
        value,
        request.regs,
        i32::from(destination) * 8,
    );
    active
}
