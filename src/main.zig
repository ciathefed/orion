const std = @import("std");
const ascii = std.ascii;
const Lexer = @import("Lexer.zig");
const Compiler = @import("Compiler.zig");
const Register = @import("common.zig").Register;
const Opcode = @import("common.zig").Opcode;
const DataType = @import("common.zig").DataType;
const Diag = @import("Diag.zig");
const utils = @import("utils.zig");

pub const Address = struct {
    addr: usize,
    offset: usize,
};

pub const Registers = struct {
    x0: u64 = 0,
    x1: u64 = 0,
    x2: u64 = 0,
    x3: u64 = 0,
    x4: u64 = 0,
    x5: u64 = 0,
    x6: u64 = 0,
    x7: u64 = 0,
    sp: usize = 0,
    bp: usize = 0,
    ip: usize = 0,

    pub fn init() Registers {
        return .{};
    }

    pub fn set(self: *Registers, reg: Register, val: anytype) void {
        switch (reg) {
            .x0 => self.x0 = val,
            .x1 => self.x1 = val,
            .x2 => self.x2 = val,
            .x3 => self.x3 = val,
            .x4 => self.x4 = val,
            .x5 => self.x5 = val,
            .x6 => self.x6 = val,
            .x7 => self.x7 = val,
            .sp => self.sp = val,
            .bp => self.bp = val,
            .ip => self.ip = val,
        }
    }

    pub fn get(self: *Registers, reg: Register, T: anytype) T {
        return switch (reg) {
            .x0 => @as(T, @intCast(self.x0)),
            .x1 => @as(T, @intCast(self.x1)),
            .x2 => @as(T, @intCast(self.x2)),
            .x3 => @as(T, @intCast(self.x3)),
            .x4 => @as(T, @intCast(self.x4)),
            .x5 => @as(T, @intCast(self.x5)),
            .x6 => @as(T, @intCast(self.x6)),
            .x7 => @as(T, @intCast(self.x7)),
            .sp => @as(T, @intCast(self.sp)),
            .bp => @as(T, @intCast(self.bp)),
            .ip => @as(T, @intCast(self.ip)),
        };
    }
};

pub const VM = struct {
    mem: []u8,
    regs: Registers,
    halted: bool,
    diag: Diag,
    allocator: std.mem.Allocator,

    pub fn init(program: []u8, mem_size: usize, allocator: std.mem.Allocator) !VM {
        var mem = try allocator.alloc(u8, mem_size);
        @memcpy(mem[0..program.len], program[0..]);

        return .{
            .mem = mem,
            .regs = .init(),
            .halted = false,
            .diag = .init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *VM) void {
        self.allocator.free(self.mem);
        self.diag.deinit();
    }

    pub fn step(self: *VM) !void {
        const ip = self.regs.get(.ip, usize);
        const inst = self.mem[ip];
        if (!Opcode.isValid(inst)) {
            try self.diag.err("unknown opcode \"{X:02}\"", .{inst}, null);
            return error.UnknownOpcode;
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
                const addr = try self.readAddress();
                const ptr = addr.addr + addr.offset;

                switch (dt) {
                    .byte => {
                        const byte = try self.readByteFrom(ptr);
                        self.regs.set(dst, byte);
                    },
                    .word => {
                        const word = try self.readWordFrom(ptr);
                        self.regs.set(dst, word);
                    },
                    .dword => {
                        const dword = try self.readDwordFrom(ptr);
                        self.regs.set(dst, dword);
                    },
                    .qword => {
                        const qword = try self.readQwordFrom(ptr);
                        self.regs.set(dst, qword);
                    },
                }
            },
            .hlt => self.halted = true,
            else => {
                try self.diag.err("unknown opcode \"{X:02}\"", .{inst}, null);
                return error.UnknownOpcode;
            },
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
        const ip = self.regs.get(.ip, usize);
        const qword = try self.readByteFrom(ip);
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
        const ip = self.regs.get(.ip, usize);
        const qword = try self.readWordFrom(ip);
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
        const ip = self.regs.get(.ip, usize);
        const qword = try self.readDwordFrom(ip);
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
        const ip = self.regs.get(.ip, usize);
        const qword = try self.readQwordFrom(ip);
        self.advance(@sizeOf(u64));
        return qword;
    }

    fn readAddress(self: *VM) !Address {
        const addr: usize = @intCast(try self.readQword());
        const offset: usize = @intCast(try self.readQword());
        return .{ .addr = addr, .offset = offset };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var arean = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arean.deinit();
    const allocator = arean.allocator();

    const file_name = "test.oasm";
    const input = try utils.readFile(file_name, allocator);

    var lexer = Lexer.init(file_name, input, allocator);
    var compiler = Compiler.init(&lexer, allocator) catch |err| switch (err) {
        error.LexerError => {
            try lexer.diag.printAllOrError(err);
            std.process.exit(1);
        },
        else => return err,
    };

    compiler.compile() catch |err| {
        try compiler.diag.printAllOrError(err);
        std.process.exit(1);
    };

    const bytecode = try compiler.bytecode.toOwnedSlice();

    // try std.fs.cwd().writeFile(.{
    //     .sub_path = "app.bin",
    //     .data = bytecode,
    // });

    var vm = try VM.init(bytecode, 1024, gpa.allocator());
    defer vm.deinit();
    vm.run() catch |err| {
        try vm.diag.printAllOrError(err);
    };

    std.debug.print("{any}\n", .{vm.regs});
}
