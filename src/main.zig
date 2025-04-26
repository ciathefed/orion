const std = @import("std");
const ascii = std.ascii;
const Lexer = @import("Lexer.zig");
const Compiler = @import("Compiler.zig");
const VM = @import("VM.zig");
const utils = @import("utils.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var args = try std.process.argsWithAllocator(gpa.allocator());
    defer args.deinit();

    const program = args.next().?;
    const file_path = blk: {
        if (args.next()) |v| break :blk v;
        std.debug.print("Usage: {s} <input.oasm>\n", .{program});
        std.process.exit(1);
    };

    var arean = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arean.deinit();
    const allocator = arean.allocator();

    const input = try utils.readFile(file_path, allocator);

    var lexer = Lexer.init(file_path, input, allocator);
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

    var vm = try VM.init(bytecode, 1024, gpa.allocator());
    defer vm.deinit();
    vm.run() catch |err| {
        try vm.diag.printAllOrError(err);
    };
}
