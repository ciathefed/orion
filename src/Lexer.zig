const std = @import("std");
const ascii = std.ascii;
const Token = @import("Token.zig");
const Diag = @import("Diag.zig");
const StringBuilder = @import("StringBuilder.zig");
const utils = @import("utils.zig");

const Lexer = @This();

pub const data_types = std.StaticStringMap(Token.Kind).initComptime(.{
    .{ "BYTE", .dt_byte },
    .{ "WORD", .dt_word },
    .{ "DWORD", .dt_dword },
    .{ "QWORD", .dt_qword },
});

pub const keywords = std.StaticStringMap(Token.Kind).initComptime(.{
    .{ "nop", .kw_nop },
    .{ "mov", .kw_mov },
    .{ "ldr", .kw_ldr },
    .{ "str", .kw_str },
    .{ "push", .kw_push },
    .{ "pop", .kw_pop },
    .{ "add", .kw_add },
    .{ "sub", .kw_sub },
    .{ "mul", .kw_mul },
    .{ "div", .kw_div },
    .{ "mod", .kw_mod },
    .{ "and", .kw_and },
    .{ "or", .kw_or },
    .{ "xor", .kw_xor },
    .{ "shl", .kw_shl },
    .{ "shr", .kw_shr },
    .{ "cmp", .kw_cmp },
    .{ "jmp", .kw_jmp },
    .{ "jeq", .kw_jeq },
    .{ "jne", .kw_jne },
    .{ "jlt", .kw_jlt },
    .{ "jgt", .kw_jgt },
    .{ "jle", .kw_jle },
    .{ "jge", .kw_jge },
    .{ "call", .kw_call },
    .{ "ret", .kw_ret },
    .{ "syscall", .kw_syscall },
    .{ "hlt", .kw_hlt },

    .{ "db", .kw_db },
    .{ "dw", .kw_dw },
    .{ "dd", .kw_dd },
    .{ "dq", .kw_dq },
});

pub const registers = [_][]const u8{
    "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
    "sp", "bp", "ip",
};

pos: usize,
read_pos: usize,
ch: u8,
in_string: bool,
input: []const u8,
loc: Diag.Location,
diag: Diag,
allocator: std.mem.Allocator,

pub fn init(file_name: []const u8, input: []const u8, allocator: std.mem.Allocator) Lexer {
    var lexer = Lexer{
        .pos = 0,
        .read_pos = 0,
        .ch = 0,
        .in_string = false,
        .input = input,
        .loc = .{
            .file = file_name,
            .line = 0,
            .col = 0,
        },
        .diag = .init(allocator),
        .allocator = allocator,
    };
    lexer.readChar();
    return lexer;
}

pub fn nextToken(self: *Lexer) !Token {
    var token: Token = undefined;
    self.skipWhitespace();

    if (self.ch == ';') {
        self.skipComment();
        return self.nextToken();
    }

    const start = self.pos;
    const loc = self.loc;

    switch (self.ch) {
        ',' => token = self.newToken(.comma, self.input[start..self.read_pos], null),
        ':' => token = self.newToken(.colon, self.input[start..self.read_pos], null),
        '[' => token = self.newToken(.lbracket, self.input[start..self.read_pos], null),
        ']' => token = self.newToken(.rbracket, self.input[start..self.read_pos], null),
        '"' => token = try self.readString(),
        0 => token = self.newToken(.eof, "", null),
        else => {
            if (ascii.isDigit(self.ch) or self.ch == '-') {
                return self.readNumber();
            } else if (isIdent(self.ch)) {
                while (isIdent(self.ch)) {
                    self.readChar();
                }

                const literal = self.input[start..self.pos];

                if (data_types.get(literal)) |kind| {
                    return self.newToken(kind, literal, loc);
                } else if (keywords.get(literal)) |kind| {
                    return self.newToken(kind, literal, loc);
                } else {
                    for (registers) |register| {
                        if (std.mem.eql(u8, literal, register)) {
                            return self.newToken(.register, literal, loc);
                        }
                    }
                    return self.newToken(.ident, literal, loc);
                }
            } else {
                try self.diag.err("illegal token", .{}, loc);
                return error.IllegalToken;
            }
        },
    }

    self.readChar();
    return token;
}

fn newToken(self: *Lexer, kind: Token.Kind, literal: []const u8, loc: ?Diag.Location) Token {
    return .{
        .kind = kind,
        .literal = literal,
        .loc = if (loc) |v| v else self.loc,
    };
}

fn peekChar(self: *Lexer) u8 {
    return if (self.read_pos >= self.input.len) 0 else self.input[self.read_pos];
}

fn readChar(self: *Lexer) void {
    if (self.read_pos >= self.input.len) {
        self.ch = 0;
    } else {
        self.ch = self.input[self.read_pos];
    }
    self.pos = self.read_pos;
    self.read_pos += 1;

    if (self.ch == '\n') {
        if (!self.in_string) {
            self.loc.line += 1;
            self.loc.col = 0;
        } else {
            self.loc.col += 1;
        }
    } else if (self.ch != 0) {
        self.loc.col += 1;
    }
}

fn readString(self: *Lexer) !Token {
    const loc = self.loc;
    self.readChar();

    const start = self.pos;
    while (self.ch != '"' and self.ch != 0) {
        self.readChar();
    }

    if (self.ch != '"') {
        try self.diag.err("unterminated string", .{}, loc);
        return error.UnterminatedString;
    }
    const end = self.pos;

    return self.newToken(.string, self.input[start..end], loc);
}

fn readNumber(self: *Lexer) !Token {
    const loc = self.loc;
    const start = self.pos;
    var has_dot = false;

    while (ascii.isDigit(self.ch) or self.ch == '.' or self.ch == '-') {
        if (self.ch == '.') {
            if (has_dot) break;
            has_dot = true;
        }
        self.readChar();
    }

    const literal = self.input[start..self.pos];
    return self.newToken(if (has_dot) .float else .integer, literal, loc);
}

fn skipWhitespace(self: *Lexer) void {
    while (ascii.isWhitespace(self.ch)) {
        self.readChar();
    }
}

fn skipComment(self: *Lexer) void {
    while (self.ch != '\n' and self.ch != 0) {
        self.readChar();
    }
    self.skipWhitespace();
}

fn isIdent(ch: u8) bool {
    return ascii.isAlphanumeric(ch) or ch == '_';
}
