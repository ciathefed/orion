const Diag = @import("Diag.zig");

pub const Kind = enum {
    eof,

    ident,
    integer,
    float,
    string,
    register,

    comma,
    colon,
    lbracket,
    rbracket,

    dt_byte,
    dt_word,
    dt_dword,
    dt_qword,

    kw_nop,
    kw_mov,
    kw_ldr,
    kw_str,
    kw_syscall,
    kw_hlt,

    kw_db,

    pub fn isDataType(self: Kind) bool {
        return switch (self) {
            .dt_byte, .dt_word, .dt_dword, .dt_qword => true,
            else => false,
        };
    }
};

kind: Kind,
literal: []const u8,
loc: Diag.Location,
