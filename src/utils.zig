const std = @import("std");
const fs = std.fs;

pub fn readFile(file_path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const stat = try fs.cwd().statFile(file_path);
    const buffer = try allocator.alloc(u8, @intCast(stat.size));
    return fs.cwd().readFile(file_path, buffer);
}
