const std = @import("std");
const plist = @import("plist.zig");

const PlistValue = plist.PlistValue;

extern fn system([*:0]const u8) c_int;

pub const PlistParser = struct {
    pub fn parse(allocator: std.mem.Allocator, content: []const u8, debug: bool) !PlistValue {
        const ptype = plist.BinOrXML(content) catch return error.ParseError;

        const xml = switch (ptype) {
            .XML => content,
            .BIN => try convertBinToXML(allocator, content),
        };

        if (xml.len == 0) return error.ParseError;

        var tok = tokenIterator(xml);
        var count: usize = 0;

        while (tok.next()) |t| {
            count += 1;
            if (debug and count <= 10) {
                switch (t) {
                    .open => |tag| std.debug.print("    Token {}: open '{s}'\n", .{count, tag}),
                    .close => |tag| std.debug.print("    Token {}: close '{s}'\n", .{count, tag}),
                    .self_close => |tag| std.debug.print("    Token {}: self_close '{s}'\n", .{count, tag}),
                    .text => |txt| std.debug.print("    Token {}: text '{s}'\n", .{count, txt[0..@min(40, txt.len)]}),
                }
            }
            switch (t) {
                .open => |tag| {
                    if (std.mem.eql(u8, tag, "plist")) {
                        if (debug) std.debug.print("    Found plist, calling parseNode\n", .{});
                        const val = try parseNode(allocator, &tok, false, debug);
                        return val;
                    }
                },
                else => continue,
            }
        }

        return error.ParseError;
    }

    fn parseNode(allocator: std.mem.Allocator, tok: *TokenIterator, eat_text: bool, debug: bool) error{ ParseError, OutOfMemory }!PlistValue {
        if (eat_text) {
            if (tok.next()) |t| {
                switch (t) {
                    .text => {},
                    else => return error.ParseError,
                }
            } else return error.ParseError;
        }

        var t = tok.next() orelse return error.ParseError;
        
        if (debug) {
            switch (t) {
                .open => |tag| std.debug.print("    parseNode got: open '{s}'\n", .{tag}),
                .close => |tag| std.debug.print("    parseNode got: close '{s}'\n", .{tag}),
                .self_close => |tag| std.debug.print("    parseNode got: self_close '{s}'\n", .{tag}),
                .text => |txt| std.debug.print("    parseNode got: text '{s}'\n", .{txt[0..@min(40, txt.len)]}),
            }
        }
        
        // Skip whitespace-only text tokens (but stop at first non-whitespace text)
        while (true) {
            switch (t) {
                .text => |txt| {
                    const trimmed = std.mem.trim(u8, txt, " \t\n\r");
                    if (trimmed.len == 0) {
                        t = tok.next() orelse return error.ParseError;
                        if (debug) {
                            switch (t) {
                                .open => |tag| std.debug.print("    After skip whitespace: open '{s}'\n", .{tag}),
                                .text => |txt2| std.debug.print("    After skip whitespace: text '{s}'\n", .{txt2[0..@min(40, txt2.len)]}),
                                else => {},
                            }
                        }
                        continue;
                    } else {
                        // Non-whitespace text - this is an error in parseNode context
                        if (debug) std.debug.print("    parseNode ERROR: non-whitespace text\n", .{});
                        return error.ParseError;
                    }
                },
                else => {},
            }
            break;
        }
        
        switch (t) {
            .self_close => |tag| {
                if (std.mem.eql(u8, tag, "true")) return PlistValue{ .boolean = true };
                if (std.mem.eql(u8, tag, "false")) return PlistValue{ .boolean = false };
                return error.ParseError;
            },
            .open => |tag| {
                if (std.mem.eql(u8, tag, "dict")) {
                    if (debug) std.debug.print("    Calling parseDict\n", .{});
                    return parseDict(allocator, tok, debug);
                }
                if (std.mem.eql(u8, tag, "array")) {
                    if (debug) std.debug.print("    Calling parseArray\n", .{});
                    return parseArray(allocator, tok, debug);
                }
                if (std.mem.eql(u8, tag, "string")) return parsePrimitive(allocator, tok, "string");
                if (std.mem.eql(u8, tag, "integer")) return parsePrimitive(allocator, tok, "integer");
                if (std.mem.eql(u8, tag, "real")) return parsePrimitive(allocator, tok, "real");
                if (std.mem.eql(u8, tag, "date")) return parsePrimitive(allocator, tok, "date");
                if (std.mem.eql(u8, tag, "data")) return parsePrimitive(allocator, tok, "data");
                return error.ParseError;
            },
            .text, .close => return error.ParseError,
        }
    }

    fn parseDict(allocator: std.mem.Allocator, tok: *TokenIterator, debug: bool) error{ ParseError, OutOfMemory }!PlistValue {
        var map: std.StringHashMapUnmanaged(PlistValue) = .empty;

        while (true) {
            const t = tok.next() orelse {
                if (debug) std.debug.print("    parseDict: no token\n", .{});
                return error.ParseError;
            };
            if (debug) {
                switch (t) {
                    .open => |tag| std.debug.print("    parseDict got: open '{s}'\n", .{tag}),
                    .close => |tag| std.debug.print("    parseDict got: close '{s}'\n", .{tag}),
                    .text => |txt| std.debug.print("    parseDict got: text '{s}'\n", .{txt[0..@min(20, txt.len)]}),
                    else => {},
                }
            }
            switch (t) {
                .close => |tag| {
                    if (std.mem.eql(u8, tag, "dict")) return PlistValue{ .dict = map };
                    return error.ParseError;
                },
                .open => |tag| {
                    if (!std.mem.eql(u8, tag, "key")) {
                        if (debug) std.debug.print("    parseDict ERROR: expected key, got '{s}'\n", .{tag});
                        return error.ParseError;
                    }

                    const key_text = tok.next() orelse return error.ParseError;
                    const key = switch (key_text) {
                        .text => |s| s,
                        else => {
                            if (debug) {
                                switch (key_text) {
                                    .open => |tag2| std.debug.print("    parseDict ERROR: expected text, got open '{s}'\n", .{tag2}),
                                    else => std.debug.print("    parseDict ERROR: expected text, got other\n", .{}),
                                }
                            }
                            return error.ParseError;
                        },
                    };
                    if (debug) std.debug.print("    parseDict key: '{s}'\n", .{key[0..@min(30, key.len)]});

                    const close = tok.next() orelse return error.ParseError;
                    switch (close) {
                        .close => |ct| {
                            if (!std.mem.eql(u8, ct, "key")) return error.ParseError;
                        },
                        else => return error.ParseError,
                    }

                    if (debug) std.debug.print("    parseDict: calling parseNode for value...\n", .{});
                    const value = try parseNode(allocator, tok, false, debug);
                    if (debug) std.debug.print("    parseDict: got value, adding to map\n", .{});
                    const key_dup = try allocator.dupe(u8, key);
                    map.put(allocator, key_dup, value) catch {};
                },
                .text => continue,
                else => return error.ParseError,
            }
        }
    }

    fn parseArray(allocator: std.mem.Allocator, tok: *TokenIterator, debug: bool) !PlistValue {
        var items: std.ArrayList(PlistValue) = .empty;
        errdefer items.deinit(allocator);

        while (true) {
            const t = tok.next() orelse return error.ParseError;
            if (debug) {
                switch (t) {
                    .open => |tag| std.debug.print("    parseArray got: open '{s}'\n", .{tag}),
                    .close => |tag| std.debug.print("    parseArray got: close '{s}'\n", .{tag}),
                    .text => |txt| std.debug.print("    parseArray got: text '{s}'\n", .{txt[0..@min(20, txt.len)]}),
                    else => {},
                }
            }
            switch (t) {
                .close => |tag| {
                    if (std.mem.eql(u8, tag, "array")) {
                        if (debug) std.debug.print("    parseArray: returning array with {} items\n", .{items.items.len});
                        return PlistValue{ .array = try items.toOwnedSlice(allocator) };
                    }
                    if (debug) std.debug.print("    parseArray ERROR: unexpected close tag '{s}'\n", .{tag});
                    return error.ParseError;
                },
                .self_close => |tag| {
                    if (std.mem.eql(u8, tag, "true")) {
                        try items.append(allocator, PlistValue{ .boolean = true });
                    } else if (std.mem.eql(u8, tag, "false")) {
                        try items.append(allocator, PlistValue{ .boolean = false });
                    } else {
                        if (debug) std.debug.print("    parseArray ERROR: unknown self_close '{s}'\n", .{tag});
                        return error.ParseError;
                    }
                },
                .open => |tag| {
                    if (debug) std.debug.print("    parseArray: handling open '{s}'\n", .{tag});
                    const val = if (std.mem.eql(u8, tag, "dict"))
                        try parseDict(allocator, tok, debug)
                    else if (std.mem.eql(u8, tag, "array"))
                        try parseArray(allocator, tok, debug)
                    else if (std.mem.eql(u8, tag, "string"))
                        try parsePrimitive(allocator, tok, "string")
                    else if (std.mem.eql(u8, tag, "integer"))
                        try parsePrimitive(allocator, tok, "integer")
                    else if (std.mem.eql(u8, tag, "real"))
                        try parsePrimitive(allocator, tok, "real")
                    else if (std.mem.eql(u8, tag, "date"))
                        try parsePrimitive(allocator, tok, "date")
                    else if (std.mem.eql(u8, tag, "data"))
                        try parsePrimitive(allocator, tok, "data")
                    else {
                        if (debug) std.debug.print("    parseArray ERROR: unknown open tag '{s}'\n", .{tag});
                        return error.ParseError;
                    };
                    try items.append(allocator, val);
                },
                .text => continue,
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
        // Write binary plist to temp file
        const tmp_in = "/tmp/zenkai_plist_in.bin";
        const tmp_out = "/tmp/zenkai_plist_out.xml";
        
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const cwd = std.Io.Dir.cwd();
        
        {
            const file = try std.Io.Dir.createFile(cwd, io, tmp_in, .{});
            defer std.Io.File.close(file, io);
            var buf: [4096]u8 = undefined;
            var writer = std.Io.File.Writer.init(file, io, &buf);
            try writer.interface.writeAll(input);
            try writer.flush();
        }
        defer std.Io.Dir.deleteFile(cwd, io, tmp_in) catch {};
        defer std.Io.Dir.deleteFile(cwd, io, tmp_out) catch {};
        
        // Convert using plutil
        const exit_code = system("plutil -convert xml1 -o /tmp/zenkai_plist_out.xml /tmp/zenkai_plist_in.bin");
        if (exit_code != 0) {
            return error.ParseError;
        }
        
        // Read converted XML
        const xml_file = try std.Io.Dir.openFile(cwd, io, tmp_out, .{});
        defer std.Io.File.close(xml_file, io);
        
        const stat = try std.Io.Dir.statFile(cwd, io, tmp_out, .{});
        const size = @as(usize, @intCast(stat.size));
        
        var buf: [4096]u8 = undefined;
        var reader = std.Io.File.Reader.init(xml_file, io, &buf);
        const xml = try reader.interface.readAlloc(allocator, size);
        
        if (xml.len == 0) {
            allocator.free(xml);
            return error.ParseError;
        }
        
        return xml;
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

        // Skip XML declarations <?...?> and DOCTYPE/comments <!...>
        if (self.input[self.pos] == '?') {
            while (self.pos < self.input.len) {
                if (self.input[self.pos] == '?' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
                    self.pos += 2;
                    return self.next();
                }
                self.pos += 1;
            }
            return null;
        }
        if (self.input[self.pos] == '!') {
            while (self.pos < self.input.len and self.input[self.pos] != '>') {
                self.pos += 1;
            }
            if (self.pos < self.input.len) self.pos += 1;
            return self.next();
        }

        const is_close = self.input[self.pos] == '/';
        if (is_close) self.pos += 1;

        const tag_start = self.pos;
        // Extract tag name only (stop at space, >, or /)
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '>' or c == '/' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return null;

        const tag_name = self.input[tag_start..self.pos];
        
        // Skip any attributes (everything until > or />)
        while (self.pos < self.input.len and self.input[self.pos] != '>' and self.input[self.pos] != '/') {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return null;

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
