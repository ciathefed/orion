const std = @import("std");
const args = @import("args");
const Lexer = @import("../Lexer.zig");
const Compiler = @import("../Compiler.zig");
const VM = @import("../VM.zig");
const utils = @import("../utils.zig");

pub const Options = struct {
    output: ?[]const u8 = null,
    run: bool = false,
    @"memory-size": usize = 65536,

    pub const shorthands = .{
        .o = "output",
        .r = "run",
        .m = "memory-size",
    };

    pub const meta = .{
        .usage_summary = "INPUT [OPTIONS]",
        .full_text =
        \\Compile assembly to bytecode
        ,
        .option_docs = .{
            .output = "Output file for bytecode (default: app.ob)",
            .run = "Execute bytecode in the virtual machine",
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
    const output_path = options.output orelse "app.ob";
    var input_path: ?[]const u8 = null;

    for (main_options.positionals) |arg| {
        if (input_path != null) {
            std.log.err("unexpected positional argument: {s}\n", .{arg});
            return error.CommandError;
        }
        input_path = arg;
    }

    if (main_options.options.help) {
        try args.printHelp(Options, "orion build", writer);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const input = try utils.readFile(input_path.?, arena.allocator());

    var lexer = Lexer.init(input_path.?, input, arena.allocator());
    var compiler = Compiler.init(&lexer, arena.allocator()) catch |err| switch (err) {
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

    try std.fs.cwd().writeFile(.{
        .sub_path = output_path,
        .data = bytecode,
    });

    if (options.run) {
        var vm = try VM.init(bytecode, options.@"memory-size", allocator);
        defer vm.deinit();
        vm.run() catch |err| {
            try vm.diag.printAllOrError(err);
        };
    }
}
