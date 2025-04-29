const std = @import("std");

const Preprocessor = @This();

const DEBUG = false;

pub const Line = struct {
    data: []const u8,
    n: usize,
    indent: []const u8,

    pub fn print(self: Line) void {
        std.debug.print("{d} | {s}\n", .{ self.n, self.data });
    }
};

pub const LocationInformation = struct {
    file: []const u8,
    line: usize,
    col: usize,
};

pub const Constant = struct {
    value: []const u8,
    line: usize,
    col: usize,
};

pub const Macro = struct {
    params: []const []const u8,
    lines: std.ArrayList([]const u8),
    line: usize,
    col: usize,
};

allocator: std.mem.Allocator,
lines: std.ArrayList(Line),
file_path: []const u8,
constants: std.StringHashMap(*Constant),
macros: std.StringHashMap(*Macro),
included_files: std.StringHashMap(*LocationInformation),

pub fn init(file_path: []const u8, allocator: std.mem.Allocator) !*Preprocessor {
    const self = try allocator.create(Preprocessor);
    self.* = Preprocessor{
        .allocator = allocator,
        .lines = std.ArrayList(Line).init(allocator),
        .file_path = file_path,
        .constants = std.StringHashMap(*Constant).init(allocator),
        .macros = std.StringHashMap(*Macro).init(allocator),
        .included_files = std.StringHashMap(*LocationInformation).init(allocator),
    };
    try self.readSourceFile(file_path);
    return self;
}

pub fn process(self: *Preprocessor) !void {
    var lines_idx: usize = 0;
    var current_macro: ?*Macro = null;

    while (lines_idx < self.lines.items.len) {
        var line = &self.lines.items[lines_idx];
        line.data = std.mem.trim(u8, line.data, " \t\r\n");

        var in_string = false;
        var was_comment = false;
        var i: usize = 0;
        while (i < line.data.len) : (i += 1) {
            if (line.data[i] == '"') {
                in_string = !in_string;
            } else if (!in_string and line.data[i] == ';') {
                line.data = line.data[0..i];
                was_comment = true;
                break;
            }
        }

        if (was_comment) {
            line.data = std.mem.trimRight(u8, line.data, " \t");
            if (line.data.len == 0) {
                _ = self.lines.orderedRemove(lines_idx);
                try self.lines.insert(lines_idx, Line{ .n = line.n, .data = "\n", .indent = "" });
                continue;
            }
        }

        if (std.mem.startsWith(u8, line.data, "#")) {
            var directive_idx: usize = 1;
            while (directive_idx < line.data.len and isAlphaNumeric(line.data[directive_idx])) {
                directive_idx += 1;
            }

            var directive_buffer: [1024]u8 = undefined;
            const directive = std.ascii.lowerString(&directive_buffer, line.data[1..directive_idx]);

            if (DEBUG) {
                std.debug.print("[{d}:{d}] Processing directive: '{s}'\n", .{ line.n, 1, directive });
            }

            if (std.mem.eql(u8, directive, "define")) {
                skipAlpha(line.data, &directive_idx);
                skipWhitespace(line.data, &directive_idx);

                const name_start = directive_idx;
                skipNonWhitespace(line.data, &directive_idx);
                const name = line.data[name_start..directive_idx];

                skipWhitespace(line.data, &directive_idx);
                const value = line.data[directive_idx..];

                if (self.constants.get(name)) |existing| {
                    existing.* = Constant{ .line = line.n, .col = name_start, .value = value };
                } else {
                    const const_val = try self.allocator.create(Constant);
                    const_val.* = Constant{ .line = line.n, .col = name_start, .value = value };
                    try self.constants.put(name, const_val);
                }
            } else if (std.mem.eql(u8, directive, "include")) {
                skipWhitespace(line.data, &directive_idx);
                const file_path = std.mem.trim(u8, line.data[directive_idx..], "\"");

                if (self.included_files.contains(file_path)) return error.CircularInclude;

                if (DEBUG) {
                    std.debug.print("[{d}:{d}] Including file '{s}'\n", .{ line.n, 1, file_path });
                }

                var included = try Preprocessor.init(file_path, self.allocator);
                try included.process();
                try self.merge(included, lines_idx + 1);
            } else if (std.mem.eql(u8, directive, "macro")) {
                const macro_name = try defineMacro(self, line, &directive_idx, &lines_idx);
                current_macro = self.macros.get(macro_name);
            } else if (std.mem.eql(u8, directive, "end")) {
                current_macro = null;
            }

            _ = self.lines.orderedRemove(lines_idx);
            try self.lines.insert(lines_idx, Line{ .n = line.n, .data = "\n", .indent = line.indent });
            continue;
        }

        lines_idx += 1;
    }

    lines_idx = 0;
    while (lines_idx < self.lines.items.len) {
        var line = &self.lines.items[lines_idx];

        var const_iter = self.constants.iterator();
        while (const_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            var index: usize = 0;
            while (index < line.data.len) {
                if (std.mem.indexOf(u8, line.data[index..], key)) |pos| {
                    const full_index = index + pos;
                    const new_len = line.data.len - key.len + val.value.len;
                    var new_data = try self.allocator.alloc(u8, new_len);

                    @memcpy(new_data[0..full_index], line.data[0..full_index]);
                    @memcpy(new_data[full_index..][0..val.value.len], val.value);
                    @memcpy(new_data[full_index + val.value.len ..], line.data[full_index + key.len ..]);

                    line.data = new_data;
                    index = full_index + val.value.len;
                } else break;
            }
        }

        lines_idx += 1;
    }
}

pub fn output(self: *Preprocessor) ![]u8 {
    var buffer = try std.ArrayList(u8).initCapacity(self.allocator, 1024 * 1024);
    defer buffer.deinit();

    for (self.lines.items) |line| {
        if (line.indent.len > 0 and line.indent.len < 256) {
            try buffer.appendSlice(line.indent);
        } else if (line.indent.len >= 256) {
            try buffer.appendSlice("    ");
        }
        try buffer.appendSlice(line.data);
        try buffer.append('\n');
    }

    return buffer.toOwnedSlice();
}

fn merge(self: *Preprocessor, other: *Preprocessor, line_index: usize) !void {
    const insert_index = @min(line_index, self.lines.items.len);
    try self.lines.insertSlice(insert_index, other.lines.items);

    var const_iter = other.constants.iterator();
    while (const_iter.next()) |entry| {
        try self.constants.put(entry.key_ptr.*, entry.value_ptr.*);
    }

    var macro_iter = other.macros.iterator();
    while (macro_iter.next()) |entry| {
        try self.macros.put(entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn readSourceFile(self: *Preprocessor, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var reader = std.io.bufferedReader(file.reader());
    var buf = reader.reader();

    var line_num: usize = 0;
    var line_buf: [1024]u8 = undefined;

    while (try buf.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        var indent_end: usize = 0;
        while (indent_end < line.len and (line[indent_end] == ' ' or line[indent_end] == '\t')) {
            indent_end += 1;
        }

        const indent = if (indent_end > 0) line[0..indent_end] else "";
        const content = std.mem.trimRight(u8, line[indent_end..], "\r");

        try self.lines.append(Line{
            .n = line_num,
            .data = try self.allocator.dupe(u8, content),
            .indent = try self.allocator.dupe(u8, indent),
        });
        line_num += 1;
    }
}

fn defineMacro(self: *Preprocessor, line: *Line, idx: *usize, lines_idx: *usize) ![]const u8 {
    skipAlpha(line.data, idx);
    skipWhitespace(line.data, idx);

    const name_start = idx.*;
    skipNonWhitespace(line.data, idx);
    const name = line.data[name_start..idx.*];

    var params = std.ArrayList([]const u8).init(self.allocator);
    while (idx.* < line.data.len) {
        skipWhitespace(line.data, idx);
        const param_start = idx.*;
        skipNonWhitespace(line.data, idx);
        if (param_start != idx.*) {
            try params.append(try self.allocator.dupe(u8, line.data[param_start..idx.*]));
        }
    }

    var new_macro = try self.allocator.create(Macro);
    new_macro.* = Macro{
        .line = line.n,
        .col = name_start,
        .params = try params.toOwnedSlice(),
        .lines = std.ArrayList([]const u8).init(self.allocator),
    };

    const body_idx = lines_idx.* + 1;
    while (body_idx < self.lines.items.len) {
        const body_line = &self.lines.items[body_idx];
        const trimmed = std.mem.trim(u8, body_line.data, " \t\r\n");

        if (std.mem.startsWith(u8, trimmed, "#end")) {
            _ = self.lines.orderedRemove(body_idx);
            break;
        }

        try new_macro.lines.append(try self.allocator.dupe(u8, body_line.data));
        _ = self.lines.orderedRemove(body_idx);
    }

    try self.macros.put(name, new_macro);
    return name;
}

fn expandMacro(self: *Preprocessor, macro_name: []const u8, args: []const []const u8, call_indent: []const u8) ![]u8 {
    const macro = self.macros.get(macro_name) orelse return error.UnknownMacro;
    if (args.len != macro.params.len) return error.WrongNumberOfArguments;

    var buffer = std.ArrayList(u8).init(self.allocator);
    for (macro.lines.items) |macro_line| {
        var expanded_line = try self.allocator.dupe(u8, macro_line);
        defer self.allocator.free(expanded_line);

        for (macro.params, 0..) |param, i| {
            while (std.mem.indexOf(u8, expanded_line, param)) |pos| {
                const new_line = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
                    expanded_line[0..pos],
                    args[i],
                    expanded_line[pos + param.len ..],
                });
                self.allocator.free(expanded_line);
                expanded_line = new_line;
            }
        }

        try buffer.appendSlice(call_indent);
        try buffer.appendSlice(expanded_line);
        try buffer.append('\n');
    }

    return buffer.toOwnedSlice();
}

fn isAlphaNumeric(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn skipAlpha(s: []const u8, idx: *usize) void {
    while (idx.* < s.len and std.ascii.isAlphabetic(s[idx.*])) : (idx.* += 1) {}
}

fn skipWhitespace(s: []const u8, idx: *usize) void {
    while (idx.* < s.len and std.ascii.isWhitespace(s[idx.*])) : (idx.* += 1) {}
}

fn skipNonWhitespace(s: []const u8, idx: *usize) void {
    while (idx.* < s.len and !std.ascii.isWhitespace(s[idx.*])) : (idx.* += 1) {}
}
