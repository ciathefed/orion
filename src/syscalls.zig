const std = @import("std");
const posix = std.posix;
const VM = @import("VM.zig");

pub const SyscallFn = *const fn (vm: *VM) anyerror!void;

pub fn exit(vm: *VM) anyerror!void {
    const status = vm.regs.get(.x0, u8);
    posix.exit(status);
}

pub fn read(vm: *VM) anyerror!void {
    const fd = vm.regs.get(.x0, i32);
    const ptr = vm.regs.get(.x1, usize);
    const len = vm.regs.get(.x2, usize);

    const n = try posix.read(fd, vm.mem[ptr .. ptr + len]);

    vm.regs.set(.x0, n);
}

pub fn write(vm: *VM) anyerror!void {
    const fd = vm.regs.get(.x0, i32);
    const ptr = vm.regs.get(.x1, usize);
    const len = vm.regs.get(.x2, usize);

    const n = try posix.write(fd, vm.mem[ptr .. ptr + len]);

    vm.regs.set(.x0, n);
}

pub fn open(vm: *VM) anyerror!void {
    const path = readString(vm.mem, vm.regs.get(.x0, usize));
    const flags = vm.regs.get(.x1, u32);
    const mode = vm.regs.get(.x2, posix.mode_t);

    const fd = try posix.open(path, @bitCast(flags), mode);

    vm.regs.set(.x0, fd);
}

pub fn close(vm: *VM) anyerror!void {
    const fd = vm.regs.get(.x0, i32);

    posix.close(fd);
}

fn readString(buffer: []u8, addr: usize) []const u8 {
    var size: usize = 0;
    for (buffer[addr..]) |ch| {
        if (ch == 0) break;
        size += 1;
    }
    return buffer[addr .. addr + size];
}

// TODO: remove, only for testing
pub fn printRegister(vm: *VM) anyerror!void {
    const value: i64 = @bitCast(vm.regs.get(.x0, u64));
    std.debug.print("{}\n", .{value});
}

pub fn getAllSyscalls(allocator: std.mem.Allocator) !std.ArrayList(SyscallFn) {
    var syscalls = std.ArrayList(SyscallFn).init(allocator);

    try syscalls.append(exit);
    try syscalls.append(read);
    try syscalls.append(write);
    try syscalls.append(open);
    try syscalls.append(close);

    try syscalls.append(printRegister);

    return syscalls;
}
