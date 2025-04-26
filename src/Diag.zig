const std = @import("std");

const Diag = @This();

const Message = struct {
    pub const Kind = enum {
        err,
        warn,
    };

    kind: Kind,
    msg: []const u8,
    loc: ?Location = null,
};

pub const Location = struct {
    line: usize,
    col: usize,
    file: ?[]const u8 = null,

    pub fn format(
        self: Location,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (self.file) |file| {
            try writer.print("{s}:{d}:{d}", .{ file, self.line + 1, self.col });
        } else {
            try writer.print("{d}:{d}", .{ self.line + 1, self.col });
        }
    }
};

messages: std.ArrayList(Message),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) Diag {
    return .{
        .messages = std.ArrayList(Message).init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Diag) void {
    for (self.messages.items) |message| {
        self.allocator.free(message.msg);
    }
    self.messages.deinit();
}

pub fn hasError(self: *Diag) bool {
    for (self.messages.items) |message| {
        if (message.kind == .err) {
            return true;
        }
    }
    return false;
}

pub fn clear(self: *Diag) void {
    for (self.messages.items) |message| {
        self.allocator.free(message.msg);
    }
    self.messages.clearRetainingCapacity();
}

pub fn err(self: *Diag, comptime fmt: []const u8, args: anytype, loc: ?Location) !void {
    const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    try self.messages.append(.{ .kind = .err, .msg = msg, .loc = loc });
}

pub fn warn(self: *Diag, comptime fmt: []const u8, args: anytype, loc: ?Location) !void {
    const msg = try std.fmt.allocPrint(self.allocator, fmt, args);
    try self.messages.append(.{ .kind = .warn, .msg = msg, .loc = loc });
}

pub fn printAll(self: *Diag, writer: anytype) !void {
    for (self.messages.items) |msg| {
        const kind = switch (msg.kind) {
            .err => "ERROR",
            .warn => "WARN",
        };
        if (msg.loc) |loc| {
            try writer.print("{s}: {s}: {s}\n", .{ loc, kind, msg.msg });
        } else {
            try writer.print("{s}: {s}\n", .{ kind, msg.msg });
        }
    }
}

pub fn printAllOrError(self: *Diag, e: anyerror) !void {
    var stderr = std.io.getStdErr();
    if (!self.hasError()) {
        try stderr.writer().print("ERROR: unknown error: {s}\n", .{@errorName(e)});
    } else {
        try self.printAll(stderr.writer());
    }
}
