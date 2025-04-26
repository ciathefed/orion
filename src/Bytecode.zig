const std = @import("std");
const Opcode = @import("common.zig").Opcode;
const DataType = @import("common.zig").DataType;

const Bytecode = @This();

buffer: std.ArrayList(u8),

pub fn init(allocator: std.mem.Allocator) Bytecode {
    return .{
        .buffer = .init(allocator),
    };
}

pub fn len(self: *Bytecode) usize {
    return self.buffer.items.len;
}

pub fn emitByte(self: *Bytecode, byte: u8) !void {
    try self.buffer.append(byte);
}

pub fn emitWord(self: *Bytecode, word: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, word, .little);
    try self.buffer.appendSlice(&buf);
}

pub fn emitDword(self: *Bytecode, dword: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, dword, .little);
    try self.buffer.appendSlice(&buf);
}

pub fn emitQword(self: *Bytecode, qword: u64) !void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, qword, .little);
    try self.buffer.appendSlice(&buf);
}

pub fn emitOpcode(self: *Bytecode, opcode: Opcode) !void {
    try self.buffer.append(@intFromEnum(opcode));
}

pub fn emitDataType(self: *Bytecode, dt: DataType) !void {
    try self.buffer.append(@intFromEnum(dt));
}

pub fn toOwnedSlice(self: *Bytecode) ![]u8 {
    return self.buffer.toOwnedSlice();
}
