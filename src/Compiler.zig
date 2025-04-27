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

pub const Fixup = struct {
    label: []const u8,
    addr: usize,
    loc: Diag.Location,
};

lexer: *Lexer,
curr_token: Token,
peek_token: Token,
bytecode: Bytecode,
labels: std.StringHashMap(usize),
fixups: std.ArrayList(Fixup),
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
                    .integer => {
                        const src = try self.parseInteger();
                        try self.bytecode.emitOpcode(.mov_reg_imm);
                        try self.bytecode.emitByte(dst);
                        try self.bytecode.emitQword(src);
                    },
                    .register => {
                        const src = try self.parseRegister();
                        try self.bytecode.emitOpcode(.mov_reg_reg);
                        try self.bytecode.emitByte(dst);
                        try self.bytecode.emitByte(src);
                    },
                    .ident => {
                        try self.nextToken();
                        try self.bytecode.emitOpcode(.mov_reg_imm);
                        try self.bytecode.emitByte(dst);
                        try self.fixups.append(.{
                            .addr = self.bytecode.len(),
                            .label = self.curr_token.literal,
                            .loc = self.curr_token.loc,
                        });
                        try self.bytecode.emitQword(0);
                    },
                    else => {
                        try self.expectedError(&.{ .integer, .register, .ident }, self.peek_token.kind, self.peek_token.loc);
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
            .kw_push => {
                const dt = try self.parseDataType();
                switch (self.peek_token.kind) {
                    .integer => {
                        const src = try self.parseInteger();
                        try self.bytecode.emitOpcode(.push_imm);
                        try self.bytecode.emitDataType(dt);
                        try self.bytecode.emitQword(src);
                    },
                    .register => {
                        const src = try self.parseRegister();
                        try self.bytecode.emitOpcode(.push_reg);
                        try self.bytecode.emitDataType(dt);
                        try self.bytecode.emitByte(src);
                    },
                    .ident => {
                        try self.nextToken();
                        try self.bytecode.emitOpcode(.push_imm);
                        try self.bytecode.emitDataType(dt);
                        try self.fixups.append(.{
                            .addr = self.bytecode.len(),
                            .label = self.curr_token.literal,
                            .loc = self.curr_token.loc,
                        });
                        try self.bytecode.emitQword(0);
                    },
                    // TODO: add addressing
                    // .lbracket => {},
                    else => {
                        try self.expectedError(&.{ .integer, .register, .ident }, self.peek_token.kind, self.peek_token.loc);
                    },
                }
            },
            .kw_pop => {
                const dt = try self.parseDataType();
                switch (self.peek_token.kind) {
                    .register => {
                        const src = try self.parseRegister();
                        try self.bytecode.emitOpcode(.pop_reg);
                        try self.bytecode.emitDataType(dt);
                        try self.bytecode.emitByte(src);
                    },
                    // TODO: add addressing
                    // .lbracket => {},
                    else => {
                        try self.expectedError(&.{.register}, self.peek_token.kind, self.peek_token.loc);
                    },
                }
            },
            .kw_add => try self.compileBinaryOp(.add_reg_reg_reg, .add_reg_reg_imm),
            .kw_sub => try self.compileBinaryOp(.sub_reg_reg_reg, .sub_reg_reg_imm),
            .kw_mul => try self.compileBinaryOp(.mul_reg_reg_reg, .mul_reg_reg_imm),
            .kw_div => try self.compileBinaryOp(.div_reg_reg_reg, .div_reg_reg_imm),
            .kw_mod => try self.compileBinaryOp(.mod_reg_reg_reg, .mod_reg_reg_imm),
            .kw_and => try self.compileBinaryOp(.and_reg_reg_reg, .and_reg_reg_imm),
            .kw_or => try self.compileBinaryOp(.or_reg_reg_reg, .or_reg_reg_imm),
            .kw_xor => try self.compileBinaryOp(.xor_reg_reg_reg, .xor_reg_reg_imm),
            .kw_shl => try self.compileBinaryOp(.shl_reg_reg_reg, .shl_reg_reg_imm),
            .kw_shr => try self.compileBinaryOp(.shr_reg_reg_reg, .shr_reg_reg_imm),
            .kw_syscall => try self.bytecode.emitOpcode(.syscall),
            .kw_cmp => {
                const dst = try self.parseRegister();
                try self.expectPeek(.comma);
                switch (self.peek_token.kind) {
                    .integer => {
                        const src = try self.parseInteger();
                        try self.bytecode.emitOpcode(.cmp_reg_imm);
                        try self.bytecode.emitByte(dst);
                        try self.bytecode.emitQword(src);
                    },
                    .register => {
                        const src = try self.parseRegister();
                        try self.bytecode.emitOpcode(.cmp_reg_reg);
                        try self.bytecode.emitByte(dst);
                        try self.bytecode.emitByte(src);
                    },
                    .ident => {
                        try self.nextToken();
                        try self.bytecode.emitOpcode(.cmp_reg_imm);
                        try self.bytecode.emitByte(dst);
                        try self.fixups.append(.{
                            .addr = self.bytecode.len(),
                            .label = self.curr_token.literal,
                            .loc = self.curr_token.loc,
                        });
                        try self.bytecode.emitQword(0);
                    },
                    else => {
                        try self.expectedError(&.{ .integer, .register, .ident }, self.peek_token.kind, self.peek_token.loc);
                    },
                }
            },
            .kw_jmp, .kw_jeq, .kw_jne, .kw_jlt, .kw_jgt, .kw_jle, .kw_jge => {
                const kind = self.curr_token.kind;
                switch (self.peek_token.kind) {
                    .integer => {
                        const target = try self.parseInteger();
                        const opcode: Opcode = switch (kind) {
                            .kw_jmp => .jmp_imm,
                            .kw_jeq => .jeq_imm,
                            .kw_jne => .jne_imm,
                            .kw_jlt => .jlt_imm,
                            .kw_jgt => .jgt_imm,
                            .kw_jle => .jle_imm,
                            .kw_jge => .jge_imm,
                            else => unreachable,
                        };
                        try self.bytecode.emitOpcode(opcode);
                        try self.bytecode.emitQword(target);
                    },
                    .register => {
                        const reg = try self.parseRegister();
                        const opcode: Opcode = switch (kind) {
                            .kw_jmp => .jmp_reg,
                            .kw_jeq => .jeq_reg,
                            .kw_jne => .jne_reg,
                            .kw_jlt => .jlt_reg,
                            .kw_jgt => .jgt_reg,
                            .kw_jle => .jle_reg,
                            .kw_jge => .jge_reg,
                            else => unreachable,
                        };
                        try self.bytecode.emitOpcode(opcode);
                        try self.bytecode.emitByte(reg);
                    },
                    .ident => {
                        try self.nextToken();
                        const opcode: Opcode = switch (kind) {
                            .kw_jmp => .jmp_imm,
                            .kw_jeq => .jeq_imm,
                            .kw_jne => .jne_imm,
                            .kw_jlt => .jlt_imm,
                            .kw_jgt => .jgt_imm,
                            .kw_jle => .jle_imm,
                            .kw_jge => .jge_imm,
                            else => unreachable,
                        };
                        try self.bytecode.emitOpcode(opcode);
                        try self.fixups.append(.{
                            .addr = self.bytecode.len(),
                            .label = self.curr_token.literal,
                            .loc = self.curr_token.loc,
                        });
                        try self.bytecode.emitQword(0);
                    },
                    else => {
                        try self.expectedError(&.{ .integer, .register, .ident }, self.peek_token.kind, self.peek_token.loc);
                    },
                }
            },
            .kw_call => {
                switch (self.peek_token.kind) {
                    .integer => {
                        const src = try self.parseInteger();
                        try self.bytecode.emitOpcode(.call_imm);
                        try self.bytecode.emitQword(src);
                    },
                    .register => {
                        const src = try self.parseRegister();
                        try self.bytecode.emitOpcode(.call_reg);
                        try self.bytecode.emitByte(src);
                    },
                    .ident => {
                        try self.nextToken();
                        try self.bytecode.emitOpcode(.call_imm);
                        try self.fixups.append(.{
                            .addr = self.bytecode.len(),
                            .label = self.curr_token.literal,
                            .loc = self.curr_token.loc,
                        });
                        try self.bytecode.emitQword(0);
                    },
                    else => {
                        try self.expectedError(&.{ .integer, .register, .ident }, self.peek_token.kind, self.peek_token.loc);
                    },
                }
            },
            .kw_ret => try self.bytecode.emitOpcode(.ret),
            .kw_hlt => try self.bytecode.emitOpcode(.hlt),
            .kw_db => try self.compileData(.byte, u8),
            .kw_dw => try self.compileData(.word, u16),
            .kw_dd => try self.compileData(.dword, u32),
            .kw_dq => try self.compileData(.qword, u64),
            else => {
                try self.diag.err("unhandled token \"{s}\"", .{self.curr_token.literal}, self.curr_token.loc);
                return error.UnhandledToken;
            },
        }

        try self.nextToken();
    }

    for (self.fixups.items) |fixup| {
        if (self.labels.get(fixup.label)) |addr| {
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, @intCast(addr), .little);
            for (0..buf.len) |i| {
                self.bytecode.buffer.items[fixup.addr + i] = buf[i];
            }
        } else {
            try self.diag.err("undefined label \"{s}\"", .{fixup.label}, fixup.loc);
            return error.UndefinedLabel;
        }
    }
}

fn parseDataType(self: *Compiler) !DataType {
    return blk: {
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

fn compileBinaryOp(
    self: *Compiler,
    reg_reg_op: Opcode,
    reg_imm_op: Opcode,
) !void {
    const dst = try self.parseRegister();
    try self.expectPeek(.comma);
    const lhs = try self.parseRegister();
    try self.expectPeek(.comma);

    switch (self.peek_token.kind) {
        .integer => {
            const rhs = try self.parseInteger();
            try self.bytecode.emitOpcode(reg_imm_op);
            try self.bytecode.emitByte(dst);
            try self.bytecode.emitByte(lhs);
            try self.bytecode.emitQword(rhs);
        },
        .register => {
            const rhs = try self.parseRegister();
            try self.bytecode.emitOpcode(reg_reg_op);
            try self.bytecode.emitByte(dst);
            try self.bytecode.emitByte(lhs);
            try self.bytecode.emitByte(rhs);
        },
        .ident => {
            try self.nextToken();
            try self.bytecode.emitOpcode(reg_imm_op);
            try self.bytecode.emitByte(dst);
            try self.bytecode.emitByte(lhs);
            try self.fixups.append(.{
                .addr = self.bytecode.len(),
                .label = self.curr_token.literal,
                .loc = self.curr_token.loc,
            });
            try self.bytecode.emitQword(0);
        },
        else => {
            try self.expectedError(&.{ .integer, .register, .ident }, self.peek_token.kind, self.peek_token.loc);
        },
    }
}

fn compileDataType(self: *Compiler) !void {
    try self.bytecode.emitDataType(try self.parseDataType());
}

fn compileRegister(self: *Compiler) !void {
    try self.bytecode.emitByte(try self.parseRegister());
}

fn compileAddress(self: *Compiler) !void {
    try self.expectPeek(.lbracket);

    switch (self.peek_token.kind) {
        .ident => {
            try self.fixups.append(.{
                .addr = self.bytecode.len(),
                .label = self.peek_token.literal,
                .loc = self.peek_token.loc,
            });
            try self.bytecode.emitQword(0);
        },
        .integer => {
            const int = try std.fmt.parseInt(i64, self.peek_token.literal, 10);
            try self.bytecode.emitQword(@intCast(int));
        },
        else => {
            try self.expectedError(&.{ .ident, .integer }, self.peek_token.kind, self.peek_token.loc);
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

fn compileData(self: *Compiler, comptime size: DataType, comptime T: type) !void {
    while (true) {
        switch (self.peek_token.kind) {
            .string => {
                if (size != .byte) {
                    try self.diag.err(
                        "strings can only be used with db",
                        .{},
                        self.peek_token.loc,
                    );
                    return error.InvalidDataType;
                }
                const escaped = try self.escapeString(self.peek_token.literal, self.peek_token.loc, self.allocator);
                for (escaped) |c| {
                    try self.bytecode.emitByte(c);
                }
            },
            .integer => {
                const value = try std.fmt.parseInt(T, self.peek_token.literal, 10);
                switch (size) {
                    .byte => try self.bytecode.emitByte(@intCast(value)),
                    .word => try self.bytecode.emitWord(@intCast(value)),
                    .dword => try self.bytecode.emitDword(@intCast(value)),
                    .qword => try self.bytecode.emitQword(value),
                }
            },
            else => {
                const expected = if (size == .byte)
                    &.{ .string, .integer }
                else
                    &.{.integer};
                try self.expectedError(expected, self.peek_token.kind, self.peek_token.loc);
            },
        }
        try self.nextToken();

        if (self.peek_token.kind == .comma) {
            try self.nextToken();
        } else {
            break;
        }
    }
}

fn nextToken(self: *Compiler) !void {
    self.curr_token = self.peek_token;
    self.peek_token = self.lexer.nextToken() catch return error.LexerError;
}

fn expectPeek(self: *Compiler, kind: Token.Kind) !void {
    if (self.peek_token.kind == kind) {
        try self.nextToken();
    } else {
        try self.expectedError(&.{kind}, self.peek_token.kind, self.peek_token.loc);
    }
}

fn expectedError(
    self: *Compiler,
    expected: []const Token.Kind,
    got: Token.Kind,
    loc: Diag.Location,
) !void {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    for (expected, 0..) |kind, i| {
        if (i != 0) {
            try writer.writeAll(if (i == expected.len - 1) ", or " else ", ");
        }
        try writer.print("\"{s}\"", .{@tagName(kind)});
    }

    try self.diag.err(
        "expected token to be {s} got \"{s}\" instead",
        .{ fbs.getWritten(), @tagName(got) },
        loc,
    );
    return error.UnexpectedToken;
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
