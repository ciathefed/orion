const std = @import("std");
const args = @import("args");

const build = @import("cli/build.zig");
const run = @import("cli/run.zig");

const Options = struct {
    help: bool = false,

    pub const shorthands = .{
        .h = "help",
    };

    pub const meta = .{
        .usage_summary = "[COMMAND]",
        .option_docs = .{
            .build = "Compile assembly to bytecode",
            .run = "Execute bytecode in the virtual machine",
            .help = "Print help and exit",
        },
    };
};

const Verb = union(enum) {
    build: build.Options,
    run: run.Options,
    b: build.Options,
    r: run.Options,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const options = try args.parseWithVerbForCurrentProcess(Options, Verb, allocator, .print);
    defer options.deinit();

    const writer = std.io.getStdErr().writer();

    handleCommand(allocator, options, writer) catch |err| {
        switch (err) {
            error.CommandError => std.process.exit(1),
            else => return err,
        }
    };

    if ((!options.options.help and options.verb == null) or (options.options.help and options.verb == null)) {
        try args.printHelp(Options, "orion", writer);
        try writer.writeAll(
            \\
            \\Commands:
            \\
            \\  build        Compile assembly to bytecode
            \\  run          Execute bytecode in the virtual machine
            \\
            \\ Pass --help to any command for more information, e.g. `orion build --help`
            \\
        );
    }
}

fn handleCommand(allocator: std.mem.Allocator, options: args.ParseArgsResult(Options, Verb), writer: anytype) !void {
    const OptionsType = args.ParseArgsResult(Options, Verb);

    if (options.verb) |verb| {
        return switch (verb) {
            .build, .b => |opts| build.run(
                allocator,
                opts,
                writer,
                OptionsType,
                options,
            ),
            .run, .r => |opts| run.run(
                allocator,
                opts,
                writer,
                OptionsType,
                options,
            ),
        };
    }
}
