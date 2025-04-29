// FIXME: this is a very poor implementation.
// what if an error occurs while in the Compiler stage but for an included file?
// it will tell you the name of the file is your main one and the location will not exist.

const std = @import("std");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const Diag = @import("Diag.zig");
const utils = @import("utils.zig");

pub fn preprocess(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    input: []const u8,
) ![]u8 {
    var lexer = Lexer.init(file_name, input, allocator);
    var macros = std.StringHashMapUnmanaged([]const u8){};
    defer macros.deinit(allocator);

    var output = std.ArrayList(u8).init(allocator);
    var included_content = std.ArrayList(u8).init(allocator);
    var last_end: usize = 0;

    while (true) {
        const tok = lexer.nextToken() catch return error.PreprocessorError;
        if (tok.kind == .eof) break;

        const start = tok.loc.start;
        const end = tok.loc.end;

        try output.appendSlice(input[last_end..start]);

        if (tok.kind == .kw_define) {
            const name = try lexer.nextToken();
            const value = try lexer.nextToken();
            if (name.kind != .ident) return error.InvalidDefine;
            try macros.put(allocator, name.literal, value.literal);

            last_end = value.loc.end;
            continue;
        }

        if (tok.kind == .ident) {
            if (macros.get(tok.literal)) |val| {
                try output.appendSlice(val);
                last_end = end;
                continue;
            }
        }

        if (tok.kind == .kw_include) {
            const file_name_token = try lexer.nextToken();
            if (file_name_token.kind != .string) return error.InvalidInclude;

            const included_file_path = file_name_token.literal;
            const included_content_str = try utils.readFile(included_file_path, allocator);
            const included_output = try preprocess(allocator, included_file_path, included_content_str);

            try included_content.appendSlice(included_output);

            last_end = file_name_token.loc.end;
            continue;
        }

        try output.appendSlice(input[start..end]);
        last_end = end;
    }

    if (included_content.items.len > 0) {
        try output.appendSlice("\n\n");
        try output.appendSlice(try included_content.toOwnedSlice());
    }

    if (last_end < input.len) {
        try output.appendSlice(input[last_end..]);
    }

    return output.toOwnedSlice();
}
