const std = @import("std");
const posix = std.posix;
const VM = @import("VM.zig");

pub const SyscallFn = *const fn (vm: *VM) anyerror!void;

pub fn getAllSyscalls(allocator: std.mem.Allocator) !std.ArrayList(SyscallFn) {
    var syscalls = std.ArrayList(SyscallFn).init(allocator);

    try syscalls.append(write);

    try syscalls.append(printRegister);

    return syscalls;
}

pub fn write(vm: *VM) anyerror!void {
    const fd = vm.regs.get(.x0, i32);
    const ptr = vm.regs.get(.x1, usize);
    const len = vm.regs.get(.x2, usize);

    const bytes = vm.mem[ptr .. ptr + len];

    const n = try posix.write(fd, bytes);

    vm.regs.set(.x0, n);
}

// TODO: remove, only for testing
pub fn printRegister(vm: *VM) anyerror!void {
    const value = vm.regs.get(.x0, i64);
    std.debug.print("{}\n", .{value});
}
