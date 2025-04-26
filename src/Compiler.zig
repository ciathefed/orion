const std = @import("std");
const ascii = std.ascii;
const Diag = @import("Diag.zig");
const Lexer = @import("Lexer.zig");
const Token = @import("Token.zig");
const Bytecode = @import("Bytecode.zig");
const Opcode = @import("common.zig").Opcode;
const DataType = @import("common.zig").DataType;
const StringBuilder = @import("StringBuilder.zig");
const utils = @import("utils.zig");

const Compiler = @This();

lexer: *Lexer,
curr_token: Token,
peek_token: Token,
bytecode: Bytecode,
labels: std.StringHashMap(usize),
fixups: std.AutoHashMap(usize, []const u8),
diag: Diag,
allocator: std.mem.Allocator,

pub fn init(lexer: *Lexer, allocator: std.mem.Allocator) !Compiler {
    var compiler = Compiler{
        .lexer = lexer,
        .curr_token = undefined,
        .peek_token = undefined,
        .bytecode = .init(allocator),
        .labels = .init(allocator),
        .fixups = .init(allocator),
        .diag = .init(allocator),
        .allocator = allocator,
    };
    try compiler.nextToken();
    try compiler.nextToken();
    return compiler;
}

pub fn compile(self: *Compiler) !void {
    while (self.curr_token.kind != .eof) {
        switch (self.curr_token.kind) {
            .ident => {
                const ident = self.curr_token.literal;
                if (self.peek_token.kind == .colon) {
                    try self.nextToken();
                    try self.labels.put(ident, self.bytecode.len());
                } else {
                    try self.diag.err("unexpected token \"{s}\"", .{self.peek_token.literal}, self.peek_token.loc);
                    return error.UnexpectedToken;
                }
            },
            .kw_nop => try self.bytecode.emitOpcode(.nop),
            .kw_mov => {
                const dst = try self.parseRegister();
                try self.expectPeek(.comma);
                switch (self.peek_token.kind) {
                    .register => {
                        const src = try self.parseRegister();
                        try self.bytecode.emitOpcode(.mov_reg_reg);
                        try self.bytecode.emitByte(dst);
                        try self.bytecode.emitByte(src);
                    },
                    .integer => {
                        const src = try self.parseInteger();
                        try self.bytecode.emitOpcode(.mov_reg_imm);
                        try self.bytecode.emitByte(dst);
                        try self.bytecode.emitQword(src);
                    },
                    .float => unreachable,
                    else => {
                        try self.diag.err(
                            "expected token to be \"{s}\" or \"{s}\" got \"{s}\" instead",
                            .{ @tagName(.register), @tagName(.integer), @tagName(self.peek_token.kind) },
                            self.peek_token.loc,
                        );
                        return error.UnexpectedToken;
                    },
                }
            },
            .kw_ldr => {
                try self.bytecode.emitOpcode(.ldr);
                try self.compileDataType();
                try self.compileRegister();
                try self.expectPeek(.comma);
                try self.compileAddress();
            },
            .kw_str => {
                try self.bytecode.emitOpcode(.str);
                try self.compileDataType();
                try self.compileRegister();
                try self.expectPeek(.comma);
                try self.compileAddress();
            },
            .kw_hlt => try self.bytecode.emitOpcode(.hlt),
            .kw_db => {
                while (true) {
                    switch (self.peek_token.kind) {
                        .string => {
                            const escaped = try self.escapeString(self.peek_token.literal, self.peek_token.loc, self.allocator);
                            for (escaped) |c| {
                                try self.bytecode.emitByte(c);
                            }
                        },
                        .integer => {
                            const byte = try std.fmt.parseInt(u8, self.peek_token.literal, 10);
                            try self.bytecode.emitByte(byte);
                        },
                        else => {},
                    }
                    try self.nextToken();

                    if (self.peek_token.kind == .comma) {
                        try self.nextToken();
                    } else {
                        break;
                    }
                }
            },
            else => {
                try self.diag.err("unhandled token \"{s}\"", .{self.curr_token.literal}, self.curr_token.loc);
                return error.UnhandledToken;
            },
        }

        try self.nextToken();
    }

    var fixups_it = self.fixups.iterator();
    while (fixups_it.next()) |fixup| {
        if (self.labels.get(fixup.value_ptr.*)) |addr| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @intCast(addr), .little);
            for (0..buf.len) |i| {
                self.bytecode.buffer.items[fixup.key_ptr.* + i] = buf[i];
            }
        } else {
            // TODO: add the loc to the fixup
            try self.diag.err("undefined label \"{s}\"", .{fixup.value_ptr.*}, null);
            return error.UndefinedLabel;
        }
    }
}

fn parseInteger(self: *Compiler) !u64 {
    const int = try std.fmt.parseInt(i64, self.peek_token.literal, 10);
    try self.nextToken();
    return @bitCast(int);
}

fn parseRegister(self: *Compiler) !u8 {
    for (Lexer.registers, 0..) |register, i| {
        if (std.mem.eql(u8, register, self.peek_token.literal)) {
            try self.nextToken();
            return @intCast(i);
        }
    }
    try self.diag.err("invalid register \"{s}\"", .{self.peek_token.literal}, self.peek_token.loc);
    return error.InvalidRegister;
}

fn compileDataType(self: *Compiler) !void {
    const dt: DataType = blk: {
        if (self.peek_token.kind.isDataType()) {
            try self.nextToken();
            break :blk switch (self.curr_token.kind) {
                .dt_byte => .byte,
                .dt_word => .word,
                .dt_dword => .dword,
                .dt_qword => .qword,
                else => unreachable,
            };
        } else {
            break :blk .byte;
        }
    };
    try self.bytecode.emitDataType(dt);
}

fn compileRegister(self: *Compiler) !void {
    try self.bytecode.emitByte(try self.parseRegister());
}

fn compileAddress(self: *Compiler) !void {
    try self.expectPeek(.lbracket);

    switch (self.peek_token.kind) {
        .ident => {
            try self.fixups.put(self.bytecode.len(), self.peek_token.literal);
            try self.bytecode.emitQword(0);
        },
        .integer => {
            const int = try std.fmt.parseInt(i64, self.peek_token.literal, 10);
            try self.bytecode.emitQword(@intCast(int));
        },
        else => {
            try self.diag.err(
                "expected token to be \"{s}\" or \"{s}\" got \"{s}\" instead",
                .{ @tagName(.ident), @tagName(.integer), @tagName(self.peek_token.kind) },
                self.peek_token.loc,
            );
        },
    }
    try self.nextToken();

    switch (self.peek_token.kind) {
        .comma => try self.nextToken(),
        .rbracket => {
            try self.bytecode.emitQword(0);
            try self.nextToken();
            return;
        },
        else => {},
    }

    try self.expectPeek(.integer);

    const int = try std.fmt.parseInt(i64, self.curr_token.literal, 10);
    try self.bytecode.emitQword(@bitCast(int));

    try self.expectPeek(.rbracket);
}

fn nextToken(self: *Compiler) !void {
    self.curr_token = self.peek_token;
    self.peek_token = self.lexer.nextToken() catch return error.LexerError;
    // std.debug.print("HERE: {any}\n", .{self.peek_token.kind});
}

fn expectPeek(self: *Compiler, kind: Token.Kind) !void {
    if (self.peek_token.kind == kind) {
        try self.nextToken();
    } else {
        try self.diag.err(
            "expected token to be \"{s}\" got \"{s}\" instead",
            .{ @tagName(kind), @tagName(self.peek_token.kind) },
            self.peek_token.loc,
        );
        return error.UnexpectedToken;
    }
}

fn escapeString(self: *Compiler, string: []const u8, loc: Diag.Location, allocator: std.mem.Allocator) ![]u8 {
    var builder = StringBuilder.init(allocator);
    defer builder.deinit();

    var i: usize = 0;
    while (i < string.len) {
        var ch = string[i];
        if (ch == '\\') {
            i += 1;
            ch = switch (string[i]) {
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                '0' => 0,
                'x' => blk: {
                    i += 1;
                    const hi = ch;
                    if (!ascii.isHex(hi)) {
                        try self.diag.err("invalid hex escape sequence", .{}, loc);
                        return error.InvalidEscapeSequence;
                    }

                    i += 1;
                    const lo = ch;
                    if (!ascii.isHex(lo)) {
                        try self.diag.err("invalid hex escape sequence", .{}, loc);
                        return error.InvalidEscapeSequence;
                    }

                    const val = (hexCharToInt(hi) << 4) | hexCharToInt(lo);
                    break :blk val;
                },
                else => {
                    try self.diag.err("invalid escape sequence", .{}, loc);
                    return error.UnknownEscapeSequence;
                },
            };
        }
        i += 1;
        try builder.writeByte(ch);
    }

    return builder.toOwnedSlice();
}

fn hexCharToInt(ch: u8) u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => unreachable,
    };
}
