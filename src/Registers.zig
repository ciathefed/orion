const Register = @import("common.zig").Register;

const Registers = @This();

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
