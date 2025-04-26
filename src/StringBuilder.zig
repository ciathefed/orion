const std = @import("std");

const StringBuilder = @This();

buffer: std.ArrayList(u8),

pub fn init(allocator: std.mem.Allocator) StringBuilder {
    return .{
        .buffer = .init(allocator),
    };
}

pub fn deinit(self: *StringBuilder) void {
    self.buffer.deinit();
}

pub fn writeByte(self: *StringBuilder, value: u8) !void {
    try self.buffer.append(value);
}

pub fn writeString(self: *StringBuilder, value: []const u8) !void {
    try self.buffer.appendSlice(value);
}

pub fn toOwnedSlice(self: *StringBuilder) ![]u8 {
    return self.buffer.toOwnedSlice();
}
