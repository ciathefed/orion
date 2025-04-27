const std = @import("std");

pub const Opcode = enum(u8) {
    nop,
    mov_reg_imm,
    mov_reg_reg,
    push_imm,
    push_reg,
    // push_adr,
    pop_reg,
    // pop_adr,
    add_reg_reg_imm,
    add_reg_reg_reg,
    sub_reg_reg_imm,
    sub_reg_reg_reg,
    mul_reg_reg_imm,
    mul_reg_reg_reg,
    div_reg_reg_imm,
    div_reg_reg_reg,
    mod_reg_reg_imm,
    mod_reg_reg_reg,
    and_reg_reg_imm,
    and_reg_reg_reg,
    or_reg_reg_imm,
    or_reg_reg_reg,
    xor_reg_reg_imm,
    xor_reg_reg_reg,
    shl_reg_reg_imm,
    shl_reg_reg_reg,
    shr_reg_reg_imm,
    shr_reg_reg_reg,
    ldr,
    str,
    syscall,
    hlt = 0xFF,

    pub fn isValid(byte: u8) bool {
        inline for (std.meta.fields(Opcode)) |field| {
            if (field.value == byte) {
                return true;
            }
        }
        return false;
    }
};

pub const DataType = enum(u8) {
    byte,
    word,
    dword,
    qword,
};

pub const Register = enum(u8) {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x7,
    sp,
    bp,
    ip,
};
