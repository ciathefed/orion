const std = @import("std");
const args = @import("args");
const Lexer = @import("../Lexer.zig");
const Compiler = @import("../Compiler.zig");
const VM = @import("../VM.zig");
const utils = @import("../utils.zig");

pub const Options = struct {
    @"memory-size": usize = 65536,

    pub const shorthands = .{
        .m = "memory-size",
    };

    pub const meta = .{
        .usage_summary = "INPUT [OPTIONS]",
        .full_text =
        \\Execute bytecode in the virtual machine
        ,
        .option_docs = .{
            .@"memory-size" = "Memory size of virtual machine",
        },
    };
};

pub fn run(
    allocator: std.mem.Allocator,
    options: Options,
    writer: anytype,
    T: type,
    main_options: T,
) !void {
    var input_path: ?[]const u8 = null;

    for (main_options.positionals) |arg| {
        if (input_path != null) {
            std.log.err("unexpected positional argument: {s}\n", .{arg});
            return error.CommandError;
        }
        input_path = arg;
    }

    if (main_options.options.help) {
        try args.printHelp(Options, "orion run", writer);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const bytecode = try utils.readFile(input_path.?, arena.allocator());

    var vm = try VM.init(bytecode, options.@"memory-size", allocator);
    defer vm.deinit();
    vm.run() catch |err| {
        try vm.diag.printAllOrError(err);
    };
}
