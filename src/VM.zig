const std = @import("std");
const Diag = @import("Diag.zig");
const Registers = @import("Registers.zig");
const Register = @import("common.zig").Register;
const Opcode = @import("common.zig").Opcode;
const DataType = @import("common.zig").DataType;
const SyscallFn = @import("syscalls.zig").SyscallFn;
const getAllSyscalls = @import("syscalls.zig").getAllSyscalls;

const VM = @This();

mem: []u8,
regs: Registers,
flags: struct { eq: bool, lt: bool } = .{ .eq = true, .lt = true },
syscalls: std.ArrayList(SyscallFn),
halted: bool = false,
diag: Diag,
allocator: std.mem.Allocator,

pub fn init(program: []u8, mem_size: usize, allocator: std.mem.Allocator) !VM {
    var mem = try allocator.alloc(u8, mem_size);
    @memcpy(mem[0..program.len], program[0..]);

    var regs = Registers{};
    regs.set(.sp, mem.len);

    return .{
        .mem = mem,
        .regs = regs,
        .syscalls = try getAllSyscalls(allocator),
        .diag = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *VM) void {
    self.allocator.free(self.mem);
    self.syscalls.deinit();
    self.diag.deinit();
}

pub fn step(self: *VM) !void {
    const ip = self.regs.get(.ip, usize);
    const inst = self.mem[ip];
    if (!Opcode.isValid(inst)) {
        try self.diag.err("invalid opcode \"{d}\"", .{inst}, null);
        return error.InvalidOpcode;
    }
    const opcode: Opcode = @enumFromInt(inst);

    switch (opcode) {
        .nop => self.advance(1),
        .mov_reg_imm => {
            self.advance(1);
            const dst = try self.readRegister();
            const src = try self.readQword();
            self.regs.set(dst, src);
        },
        .mov_reg_reg => {
            self.advance(1);
            const dst = try self.readRegister();
            const src = try self.readRegister();
            self.regs.set(dst, self.regs.get(src, u64));
        },
        .ldr => {
            self.advance(1);
            const dt = try self.readDataType();
            const dst = try self.readRegister();
            const src = try self.readAddress();

            const addr = src.addr +% src.offset;

            switch (dt) {
                .byte => {
                    const byte = try self.readByteFrom(addr);
                    self.regs.set(dst, byte);
                },
                .word => {
                    const word = try self.readWordFrom(addr);
                    self.regs.set(dst, word);
                },
                .dword => {
                    const dword = try self.readDwordFrom(addr);
                    self.regs.set(dst, dword);
                },
                .qword => {
                    const qword = try self.readQwordFrom(addr);
                    self.regs.set(dst, qword);
                },
            }
        },
        .str => {
            self.advance(1);
            const dt = try self.readDataType();
            const src = try self.readRegister();
            const dst = try self.readAddress();

            const addr = dst.addr +% dst.offset;
            const value = self.regs.get(src, u64);

            switch (dt) {
                .byte => {
                    const slice = self.mem[addr .. addr + @sizeOf(u8)];
                    std.mem.writeInt(u8, @ptrCast(slice), @intCast(value), .little);
                },
                .word => {
                    const slice = self.mem[addr .. addr + @sizeOf(u16)];
                    std.mem.writeInt(u16, @ptrCast(slice), @intCast(value), .little);
                },
                .dword => {
                    const slice = self.mem[addr .. addr + @sizeOf(u32)];
                    std.mem.writeInt(u32, @ptrCast(slice), @intCast(value), .little);
                },
                .qword => {
                    const slice = self.mem[addr .. addr + @sizeOf(u64)];
                    std.mem.writeInt(u64, @ptrCast(slice), value, .little);
                },
            }
        },
        .push_imm => {
            self.advance(1);
            const dt = try self.readDataType();
            const src = try self.readQword();

            try self.push(src, dt);
        },
        .push_reg => {
            self.advance(1);
            const dt = try self.readDataType();
            const src = self.regs.get(try self.readRegister(), u64);

            try self.push(src, dt);
        },
        .pop_reg => {
            self.advance(1);
            const dt = try self.readDataType();
            const dst = try self.readRegister();

            const value = try self.pop(dt);
            self.regs.set(dst, value);
        },
        .add_reg_reg_reg => try self.binaryOpReg(add),
        .add_reg_reg_imm => try self.binaryOpImm(add),
        .sub_reg_reg_reg => try self.binaryOpReg(sub),
        .sub_reg_reg_imm => try self.binaryOpImm(sub),
        .mul_reg_reg_reg => try self.binaryOpReg(mul),
        .mul_reg_reg_imm => try self.binaryOpImm(mul),
        .div_reg_reg_reg => try self.binaryOpReg(div),
        .div_reg_reg_imm => try self.binaryOpImm(div),
        .mod_reg_reg_reg => try self.binaryOpReg(mod),
        .mod_reg_reg_imm => try self.binaryOpImm(mod),
        .and_reg_reg_reg => try self.binaryOpReg(@"and"),
        .and_reg_reg_imm => try self.binaryOpImm(@"and"),
        .or_reg_reg_reg => try self.binaryOpReg(@"or"),
        .or_reg_reg_imm => try self.binaryOpImm(@"or"),
        .xor_reg_reg_reg => try self.binaryOpReg(xor),
        .xor_reg_reg_imm => try self.binaryOpImm(xor),
        .shl_reg_reg_reg => try self.binaryOpReg(shl),
        .shl_reg_reg_imm => try self.binaryOpImm(shl),
        .shr_reg_reg_reg => try self.binaryOpReg(shr),
        .shr_reg_reg_imm => try self.binaryOpImm(shr),
        .cmp_reg_imm => {
            self.advance(1);
            const lhs = self.regs.get(try self.readRegister(), u64);
            const rhs = try self.readQword();
            self.flags.eq = lhs == rhs;
            self.flags.lt = lhs < rhs;
        },
        .cmp_reg_reg => {
            self.advance(1);
            const lhs = self.regs.get(try self.readRegister(), u64);
            const rhs = self.regs.get(try self.readRegister(), u64);
            self.flags.eq = lhs == rhs;
            self.flags.lt = lhs < rhs;
        },
        // Add this to the switch statement in the step() function
        .jmp_imm => {
            self.advance(1);
            const target = try self.readQword();
            self.regs.set(.ip, target);
        },
        .jmp_reg => {
            self.advance(1);
            const reg = try self.readRegister();
            const target = self.regs.get(reg, usize);
            self.regs.set(.ip, target);
        },
        .jeq_imm => {
            self.advance(1);
            const target = try self.readQword();
            if (self.flags.eq) {
                self.regs.set(.ip, target);
            }
        },
        .jeq_reg => {
            self.advance(1);
            const reg = try self.readRegister();
            if (self.flags.eq) {
                const target = self.regs.get(reg, usize);
                self.regs.set(.ip, target);
            }
        },
        .jne_imm => {
            self.advance(1);
            const target = try self.readQword();
            if (!self.flags.eq) {
                self.regs.set(.ip, target);
            }
        },
        .jne_reg => {
            self.advance(1);
            const reg = try self.readRegister();
            if (!self.flags.eq) {
                const target = self.regs.get(reg, usize);
                self.regs.set(.ip, target);
            }
        },
        .jlt_imm => {
            self.advance(1);
            const target = try self.readQword();
            if (self.flags.lt) {
                self.regs.set(.ip, target);
            }
        },
        .jlt_reg => {
            self.advance(1);
            const reg = try self.readRegister();
            if (self.flags.lt) {
                const target = self.regs.get(reg, usize);
                self.regs.set(.ip, target);
            }
        },
        .jgt_imm => {
            self.advance(1);
            const target = try self.readQword();
            if (!self.flags.lt and !self.flags.eq) {
                self.regs.set(.ip, target);
            }
        },
        .jgt_reg => {
            self.advance(1);
            const reg = try self.readRegister();
            if (!self.flags.lt and !self.flags.eq) {
                const target = self.regs.get(reg, usize);
                self.regs.set(.ip, target);
            }
        },
        .jle_imm => {
            self.advance(1);
            const target = try self.readQword();
            if (self.flags.lt or self.flags.eq) {
                self.regs.set(.ip, target);
            }
        },
        .jle_reg => {
            self.advance(1);
            const reg = try self.readRegister();
            if (self.flags.lt or self.flags.eq) {
                const target = self.regs.get(reg, usize);
                self.regs.set(.ip, target);
            }
        },
        .jge_imm => {
            self.advance(1);
            const target = try self.readQword();
            if (!self.flags.lt) {
                self.regs.set(.ip, target);
            }
        },
        .jge_reg => {
            self.advance(1);
            const reg = try self.readRegister();
            if (!self.flags.lt) {
                const target = self.regs.get(reg, usize);
                self.regs.set(.ip, target);
            }
        },
        .syscall => {
            self.advance(1);
            const index = self.regs.get(.x7, usize);
            if (index >= self.syscalls.items.len) {
                try self.diag.err("unknown syscall \"{d}\"", .{index}, null);
                return error.UnknownOpcode;
            }
            const syscall = self.syscalls.items[index];
            try syscall(self);
        },
        .call_imm => {
            self.advance(1);
            const target = try self.readQword();

            const return_addr = self.regs.get(.ip, u64);
            try self.push(return_addr, .qword);

            self.regs.set(.ip, target);
        },
        .call_reg => {
            self.advance(1);
            const target = self.regs.get(try self.readRegister(), u64);

            const return_addr = self.regs.get(.ip, u64);
            try self.push(return_addr, .qword);

            self.regs.set(.ip, target);
        },
        .ret => {
            self.advance(1);

            const return_addr = try self.pop(.qword);

            self.regs.set(.ip, return_addr);
        },
        .hlt => self.halted = true,
        // else => {
        //     try self.diag.err("unhandled opcode \"{d}\"", .{inst}, null);
        //     return error.UnhandledOpcode;
        // },
    }
}

pub fn run(self: *VM) !void {
    while (!self.halted) {
        try self.step();
    }
}

fn advance(self: *VM, n: usize) void {
    const ip = self.regs.get(.ip, usize);
    self.regs.set(.ip, ip + n);
}

fn binaryOpReg(
    self: *VM,
    comptime opFn: fn (lhs: u64, rhs: u64) u64,
) !void {
    self.advance(1);
    const dst = try self.readRegister();
    const lhs = self.regs.get(try self.readRegister(), u64);
    const rhs = self.regs.get(try self.readRegister(), u64);
    self.regs.set(dst, opFn(lhs, rhs));
}

fn binaryOpImm(
    self: *VM,
    comptime opFn: fn (lhs: u64, rhs: u64) u64,
) !void {
    self.advance(1);
    const dst = try self.readRegister();
    const lhs = self.regs.get(try self.readRegister(), u64);
    const rhs = try self.readQword();
    self.regs.set(dst, opFn(lhs, rhs));
}

fn readDataType(self: *VM) !DataType {
    const ip = self.regs.get(.ip, usize);
    const byte = self.mem[ip];
    const dt: DataType = switch (byte) {
        0x00 => .byte,
        0x01 => .word,
        0x02 => .dword,
        0x03 => .qword,
        else => {
            try self.diag.err("unknown data type \"{}\"", .{byte}, null);
            return error.UnknownDataType;
        },
    };
    self.advance(1);
    return dt;
}

fn readRegister(self: *VM) !Register {
    const ip = self.regs.get(.ip, usize);
    const byte = self.mem[ip];
    const reg: Register = switch (byte) {
        0x00 => .x0,
        0x01 => .x1,
        0x02 => .x2,
        0x03 => .x3,
        0x04 => .x4,
        0x05 => .x5,
        0x06 => .x6,
        0x07 => .x7,
        0x08 => .sp,
        0x09 => .bp,
        0x0A => .ip,
        else => {
            try self.diag.err("unknown register \"{}\"", .{byte}, null);
            return error.UnknownRegister;
        },
    };
    self.advance(1);
    return reg;
}

fn readByteFrom(self: *VM, addr: usize) !u8 {
    const size = @sizeOf(u8);
    const end = addr + size;
    const qword = std.mem.readInt(u8, @ptrCast(self.mem[addr..end]), .little);
    return qword;
}

fn readByte(self: *VM) !u8 {
    const qword = try self.readByteFrom(self.regs.get(.ip, usize));
    self.advance(@sizeOf(u8));
    return qword;
}

fn readWordFrom(self: *VM, addr: usize) !u16 {
    const size = @sizeOf(u16);
    const end = addr + size;
    const qword = std.mem.readInt(u16, @ptrCast(self.mem[addr..end]), .little);
    return qword;
}

fn readWord(self: *VM) !u16 {
    const qword = try self.readWordFrom(self.regs.get(.ip, usize));
    self.advance(@sizeOf(u16));
    return qword;
}

fn readDwordFrom(self: *VM, addr: usize) !u32 {
    const size = @sizeOf(u32);
    const end = addr + size;
    const qword = std.mem.readInt(u32, @ptrCast(self.mem[addr..end]), .little);
    return qword;
}

fn readDword(self: *VM) !u32 {
    const qword = try self.readDwordFrom(self.regs.get(.ip, usize));
    self.advance(@sizeOf(u32));
    return qword;
}

fn readQwordFrom(self: *VM, addr: usize) !u64 {
    const size = @sizeOf(u64);
    const end = addr + size;
    const qword = std.mem.readInt(u64, @ptrCast(self.mem[addr..end]), .little);
    return qword;
}

fn readQword(self: *VM) !u64 {
    const qword = try self.readQwordFrom(self.regs.get(.ip, usize));
    self.advance(@sizeOf(u64));
    return qword;
}

fn readAddress(self: *VM) !struct { addr: usize, offset: usize } {
    const addr: usize = @intCast(try self.readQword());
    const offset: usize = @intCast(try self.readQword());
    return .{ .addr = addr, .offset = offset };
}

fn push(self: *VM, value: u64, dt: DataType) !void {
    const sp = self.regs.get(.sp, usize);
    const size: usize = switch (dt) {
        .byte => @sizeOf(u8),
        .word => @sizeOf(u16),
        .dword => @sizeOf(u32),
        .qword => @sizeOf(u64),
    };

    if (sp < size) {
        try self.diag.err("stack overflow", .{}, null);
        return error.StackOverflow;
    }

    const new_sp = sp - size;

    switch (dt) {
        .byte => {
            const slice = self.mem[new_sp .. new_sp + @sizeOf(u8)];
            std.mem.writeInt(u8, @ptrCast(slice), @truncate(value), .little);
        },
        .word => {
            const slice = self.mem[new_sp .. new_sp + @sizeOf(u16)];
            std.mem.writeInt(u16, @ptrCast(slice), @truncate(value), .little);
        },
        .dword => {
            const slice = self.mem[new_sp .. new_sp + @sizeOf(u32)];
            std.mem.writeInt(u32, @ptrCast(slice), @truncate(value), .little);
        },
        .qword => {
            const slice = self.mem[new_sp .. new_sp + @sizeOf(u64)];
            std.mem.writeInt(u64, @ptrCast(slice), value, .little);
        },
    }

    self.regs.set(.sp, new_sp);
}

fn pop(self: *VM, dt: DataType) !u64 {
    const sp = self.regs.get(.sp, usize);
    const size: usize = switch (dt) {
        .byte => @sizeOf(u8),
        .word => @sizeOf(u16),
        .dword => @sizeOf(u32),
        .qword => @sizeOf(u64),
    };

    if (sp + size > self.mem.len) {
        try self.diag.err("stack underflow", .{}, null);
        return error.StackUnderflow;
    }

    const value: u64 = switch (dt) {
        .byte => blk: {
            const slice = self.mem[sp .. sp + @sizeOf(u8)];
            break :blk std.mem.readInt(u8, @ptrCast(slice), .little);
        },
        .word => blk: {
            const slice = self.mem[sp .. sp + @sizeOf(u16)];
            break :blk std.mem.readInt(u16, @ptrCast(slice), .little);
        },
        .dword => blk: {
            const slice = self.mem[sp .. sp + @sizeOf(u32)];
            break :blk std.mem.readInt(u32, @ptrCast(slice), .little);
        },
        .qword => blk: {
            const slice = self.mem[sp .. sp + @sizeOf(u64)];
            break :blk std.mem.readInt(u64, @ptrCast(slice), .little);
        },
    };

    self.regs.set(.sp, sp + size);
    return value;
}

fn add(lhs: u64, rhs: u64) u64 {
    return lhs +% rhs;
}

fn sub(lhs: u64, rhs: u64) u64 {
    return lhs -% rhs;
}

fn mul(lhs: u64, rhs: u64) u64 {
    return lhs *% rhs;
}

fn div(lhs: u64, rhs: u64) u64 {
    return @divTrunc(lhs, rhs);
}

fn mod(lhs: u64, rhs: u64) u64 {
    return @mod(lhs, rhs);
}

fn @"and"(lhs: u64, rhs: u64) u64 {
    return lhs & rhs;
}

fn @"or"(lhs: u64, rhs: u64) u64 {
    return lhs | rhs;
}

fn xor(lhs: u64, rhs: u64) u64 {
    return lhs ^ rhs;
}

fn shl(lhs: u64, rhs: u64) u64 {
    return lhs << @intCast(rhs);
}

fn shr(lhs: u64, rhs: u64) u64 {
    return lhs >> @intCast(rhs);
}
