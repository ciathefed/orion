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

    .{ "#define", .kw_define },
    .{ "#include", .kw_include },
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
            .start = 0,
            .end = 0,
        },
        .diag = .init(allocator),
        .allocator = allocator,
    };
    lexer.readChar();
    return lexer;
}

pub fn nextToken(self: *Lexer) !Token {
    self.skipWhitespace();

    if (self.ch == ';') {
        self.skipComment();
        return self.nextToken();
    }

    const start_offset = self.pos;
    const start_line = self.loc.line;
    const start_col = self.loc.col;

    switch (self.ch) {
        ',' => {
            self.readChar();
            return self.newToken(.comma, self.input[start_offset..self.pos], start_offset, self.pos, start_line, start_col);
        },
        ':' => {
            self.readChar();
            return self.newToken(.colon, self.input[start_offset..self.pos], start_offset, self.pos, start_line, start_col);
        },
        '[' => {
            self.readChar();
            return self.newToken(.lbracket, self.input[start_offset..self.pos], start_offset, self.pos, start_line, start_col);
        },
        ']' => {
            self.readChar();
            return self.newToken(.rbracket, self.input[start_offset..self.pos], start_offset, self.pos, start_line, start_col);
        },
        '"' => return try self.readString(start_offset, start_line, start_col),
        0 => return self.newToken(.eof, "", self.pos, self.pos, self.loc.line, self.loc.col),
        else => {
            if (ascii.isDigit(self.ch) or self.ch == '-') {
                return self.readNumber(start_offset, start_line, start_col);
            } else if (isIdent(self.ch) or self.ch == '#') {
                if (self.ch == '#') self.readChar();
                while (isIdent(self.ch)) {
                    self.readChar();
                }

                const literal = self.input[start_offset..self.pos];
                if (data_types.get(literal)) |kind| {
                    return self.newToken(kind, literal, start_offset, self.pos, start_line, start_col);
                } else if (keywords.get(literal)) |kind| {
                    return self.newToken(kind, literal, start_offset, self.pos, start_line, start_col);
                } else {
                    for (registers) |register| {
                        if (std.mem.eql(u8, literal, register)) {
                            return self.newToken(.register, literal, start_offset, self.pos, start_line, start_col);
                        }
                    }
                    return self.newToken(.ident, literal, start_offset, self.pos, start_line, start_col);
                }
            } else {
                const loc = Diag.Location{
                    .file = self.loc.file,
                    .line = start_line,
                    .col = start_col,
                    .start = start_offset,
                    .end = self.read_pos,
                };
                try self.diag.err("illegal token", .{}, loc);
                return error.IllegalToken;
            }
        },
    }
}

fn newToken(self: *Lexer, kind: Token.Kind, literal: []const u8, start: usize, end: usize, line: usize, col: usize) Token {
    return .{
        .kind = kind,
        .literal = literal,
        .loc = .{
            .file = self.loc.file,
            .line = line,
            .col = col,
            .start = start,
            .end = end,
        },
    };
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

fn readString(self: *Lexer, start: usize, line: usize, col: usize) !Token {
    self.readChar();
    const str_start = self.pos;

    while (self.ch != '"' and self.ch != 0) {
        self.readChar();
    }

    if (self.ch != '"') {
        const loc = Diag.Location{
            .file = self.loc.file,
            .line = line,
            .col = col,
            .start = start,
            .end = self.pos,
        };
        try self.diag.err("unterminated string", .{}, loc);
        return error.UnterminatedString;
    }

    const str_end = self.pos;
    self.readChar();

    return self.newToken(.string, self.input[str_start..str_end], start, self.pos, line, col);
}

fn readNumber(self: *Lexer, start: usize, line: usize, col: usize) !Token {
    var has_dot = false;

    while (ascii.isDigit(self.ch) or self.ch == '.' or self.ch == '-') {
        if (self.ch == '.') {
            if (has_dot) break;
            has_dot = true;
        }
        self.readChar();
    }

    const literal = self.input[start..self.pos];
    return self.newToken(if (has_dot) .float else .integer, literal, start, self.pos, line, col);
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
