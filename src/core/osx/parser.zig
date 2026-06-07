const std = @import("std");
const plist = @import("plist.zig");

const PlistValue = plist.PlistValue;

pub const PlistParser = struct {
    pub fn parse(allocator: std.mem.Allocator, content: []const u8) !PlistValue {
        const ptype = plist.BinOrXML(content) catch {
            return error.ParseError;
        };

        const xml = switch (ptype) {
            .XML => content,
            .BIN => try convertBinToXML(allocator, content),
        };

        if (xml.len == 0) return error.ParseError;

        var tok = tokenIterator(xml);

        _ = tok.next(); // <?xml ...?>
        _ = tok.next(); // <!DOCTYPE ...>
        _ = tok.next(); // maybe another processing instruction

        while (tok.next()) |t| {
            switch (t) {
                .open => |tag| {
                    if (std.mem.eql(u8, tag, "plist")) {
                        const val = try parseNode(allocator, &tok, false);
                        return val;
                    }
                },
                else => continue,
            }
        }

        return error.ParseError;
    }

    fn parseNode(allocator: std.mem.Allocator, tok: *TokenIterator, eat_text: bool) !PlistValue {
        if (eat_text) {
            if (tok.next()) |t| {
                switch (t) {
                    .text => {},
                    else => return error.ParseError,
                }
            } else return error.ParseError;
        }

        const t = tok.next() orelse return error.ParseError;
        switch (t) {
            .self_close => |tag| {
                if (std.mem.eql(u8, tag, "true")) return PlistValue{ .boolean = true };
                if (std.mem.eql(u8, tag, "false")) return PlistValue{ .boolean = false };
                return error.ParseError;
            },
            .open => |tag| {
                if (std.mem.eql(u8, tag, "dict")) return parseDict(allocator, tok);
                if (std.mem.eql(u8, tag, "array")) return parseArray(allocator, tok);
                if (std.mem.eql(u8, tag, "string")) return parsePrimitive(allocator, tok, "string");
                if (std.mem.eql(u8, tag, "integer")) return parsePrimitive(allocator, tok, "integer");
                if (std.mem.eql(u8, tag, "real")) return parsePrimitive(allocator, tok, "real");
                if (std.mem.eql(u8, tag, "date")) return parsePrimitive(allocator, tok, "date");
                if (std.mem.eql(u8, tag, "data")) return parsePrimitive(allocator, tok, "data");
                return error.ParseError;
            },
            else => return error.ParseError,
        }
    }

    fn parseDict(allocator: std.mem.Allocator, tok: *TokenIterator) !PlistValue {
        var map: std.StringHashMapUnmanaged(PlistValue) = .empty;

        while (true) {
            const t = tok.next() orelse return error.ParseError;
            switch (t) {
                .close => |tag| {
                    if (std.mem.eql(u8, tag, "dict")) return PlistValue{ .dict = map };
                    return error.ParseError;
                },
                .open => |tag| {
                    if (!std.mem.eql(u8, tag, "key")) return error.ParseError;

                    const key_text = tok.next() orelse return error.ParseError;
                    const key = switch (key_text) {
                        .text => |s| s,
                        else => return error.ParseError,
                    };

                    const close = tok.next() orelse return error.ParseError;
                    switch (close) {
                        .close => |ct| {
                            if (!std.mem.eql(u8, ct, "key")) return error.ParseError;
                        },
                        else => return error.ParseError,
                    }

                    const value = try parseNode(allocator, tok, false);
                    const key_dup = try allocator.dupe(u8, key);
                    map.put(allocator, key_dup, value) catch {};
                },
                .text => continue,
                else => return error.ParseError,
            }
        }
    }

    fn parseArray(allocator: std.mem.Allocator, tok: *TokenIterator) !PlistValue {
        var items = std.ArrayList(PlistValue).init(allocator);
        errdefer items.deinit();

        while (true) {
            const t = tok.next() orelse return error.ParseError;
            switch (t) {
                .close => |tag| {
                    if (std.mem.eql(u8, tag, "array")) {
                        return PlistValue{ .array = try items.toOwnedSlice() };
                    }
                    return error.ParseError;
                },
                .self_close, .open => {
                    const val = try parseNode(allocator, tok, false);
                    try items.append(val);
                },
                .text => continue,
                .close => return error.ParseError,
            }
        }
    }

    fn parsePrimitive(allocator: std.mem.Allocator, tok: *TokenIterator, comptime tag: []const u8) !PlistValue {
        const text_t = tok.next() orelse return error.ParseError;
        const text = switch (text_t) {
            .text => |s| s,
            .self_close => |t| {
                if (std.mem.eql(u8, t, tag)) {
                    return PlistValue{ .string = try allocator.dupe(u8, "") };
                }
                return error.ParseError;
            },
            else => return error.ParseError,
        };

        const close = tok.next() orelse return error.ParseError;
        switch (close) {
            .close => |ct| {
                if (!std.mem.eql(u8, ct, tag)) return error.ParseError;
            },
            else => return error.ParseError,
        }

        if (comptime std.mem.eql(u8, tag, "string")) {
            return PlistValue{ .string = try allocator.dupe(u8, text) };
        }
        if (comptime std.mem.eql(u8, tag, "integer")) {
            const val = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\n\r"), 10) catch return error.ParseError;
            return PlistValue{ .integer = val };
        }
        if (comptime std.mem.eql(u8, tag, "real")) {
            const val = std.fmt.parseFloat(f64, std.mem.trim(u8, text, " \t\n\r")) catch return error.ParseError;
            return PlistValue{ .float = val };
        }
        if (comptime std.mem.eql(u8, tag, "date")) {
            return PlistValue{ .date = 0 };
        }
        if (comptime std.mem.eql(u8, tag, "data")) {
            return PlistValue{ .data = try allocator.dupe(u8, text) };
        }
        return error.ParseError;
    }

    fn convertBinToXML(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
        const plutil_args = [_][*:0]const u8{ "plutil", "-convert", "xml1", "-o", "-", "-", null };

        var proc = std.process.Child.init(&plutil_args, allocator);
        proc.stdin_behavior = .Pipe;
        proc.stdout_behavior = .Pipe;
        proc.stderr_behavior = .Ignore;

        try proc.spawn();
        try proc.stdin.?.writeAll(input);
        proc.stdin.?.close();

        const output = try proc.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
        const term = try proc.wait();

        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    allocator.free(output);
                    return error.ParseError;
                }
            },
            else => {
                allocator.free(output);
                return error.ParseError;
            },
        }

        if (output.len == 0) {
            allocator.free(output);
            return error.ParseError;
        }
        return output;
    }
};

const Token = union(enum) {
    open: []const u8,
    close: []const u8,
    self_close: []const u8,
    text: []const u8,
};

pub fn tokenIterator(input: []const u8) TokenIterator {
    return .{ .input = input, .pos = 0 };
}

pub const TokenIterator = struct {
    input: []const u8,
    pos: usize,

    fn skipWhitespace(self: *TokenIterator) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => break,
            }
        }
    }

    pub fn next(self: *TokenIterator) ?Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return null;

        if (self.input[self.pos] != '<') {
            const start = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != '<') {
                self.pos += 1;
            }
            return Token{ .text = self.input[start..self.pos] };
        }

        self.pos += 1;
        if (self.pos >= self.input.len) return null;

        const is_close = self.input[self.pos] == '/';
        if (is_close) self.pos += 1;

        const tag_start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '>' and self.input[self.pos] != '/') {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return null;

        const tag_name = std.mem.trim(u8, self.input[tag_start..self.pos], " \t");

        const is_self_close = self.input[self.pos] == '/';
        if (is_self_close) {
            self.pos += 1;
            if (self.pos >= self.input.len or self.input[self.pos] != '>') return null;
            self.pos += 1;
            return Token{ .self_close = tag_name };
        }

        self.pos += 1;

        if (is_close) return Token{ .close = tag_name };
        return Token{ .open = tag_name };
    }
};
