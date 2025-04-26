const std = @import("std");
const ascii = std.ascii;
const Lexer = @import("Lexer.zig");
const Compiler = @import("Compiler.zig");
const VM = @import("VM.zig");
const utils = @import("utils.zig");

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
}
