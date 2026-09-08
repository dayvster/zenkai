const std = @import("std");

pub const ItemKind = enum {
    text,
    file,
    image,
    html,
    unknown,

    pub fn jsonString(self: ItemKind) []const u8 {
        return switch (self) {
            .text => "text",
            .file => "file",
            .image => "image",
            .html => "html",
            .unknown => "unknown",
        };
    }

    pub fn fromString(s: []const u8) ItemKind {
        if (std.mem.eql(u8, s, "file")) return .file;
        if (std.mem.eql(u8, s, "image")) return .image;
        if (std.mem.eql(u8, s, "html")) return .html;
        if (std.mem.eql(u8, s, "text")) return .text;
        return .unknown;
    }
};

pub const HistoryItem = struct {
    kind: ItemKind,
    text: []const u8,
    payload: []const u8,
    timestamp: i64,
    pinned: bool = false,

    pub fn deinit(self: HistoryItem, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        allocator.free(self.payload);
    }
};

pub const History = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(HistoryItem),
    max_items: usize,

    pub fn init(allocator: std.mem.Allocator, max_items: usize) History {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(HistoryItem).empty,
            .max_items = max_items,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.items.items) |item| {
            item.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *History) void {
        for (self.items.items) |item| {
            item.deinit(self.allocator);
        }
        self.items.clearRetainingCapacity();
    }

    /// Add a new entry. Moves it to the top if it already exists.
    pub fn add(self: *History, kind: ItemKind, text: []const u8, payload: []const u8) !void {
        if (text.len == 0 and payload.len == 0) return;

        const effective_text = if (text.len > 0) text else payload;

        // Check if this payload is already at the front.
        if (self.items.items.len > 0 and
            self.items.items[0].kind == kind and
            std.mem.eql(u8, self.items.items[0].payload, payload))
        {
            self.items.items[0].timestamp = std.time.timestamp();
            return;
        }

        // Remove existing duplicate further down.
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].kind == kind and std.mem.eql(u8, self.items.items[i].payload, payload)) {
                const old = self.items.orderedRemove(i);
                old.deinit(self.allocator);
            } else {
                i += 1;
            }
        }

        const owned_text = try self.allocator.dupe(u8, effective_text);
        errdefer self.allocator.free(owned_text);
        const owned_payload = try self.allocator.dupe(u8, payload);
        errdefer self.allocator.free(owned_payload);

        try self.items.insert(self.allocator, 0, .{
            .kind = kind,
            .text = owned_text,
            .payload = owned_payload,
            .timestamp = std.time.timestamp(),
            .pinned = false,
        });

        self.trim();
    }

    fn trim(self: *History) void {
        while (self.items.items.len > self.max_items) {
            const old = self.items.pop();
            old.deinit(self.allocator);
        }
    }

    pub fn count(self: *const History) usize {
        return self.items.items.len;
    }

    pub fn get(self: *const History, index: usize) ?HistoryItem {
        if (index >= self.items.items.len) return null;
        return self.items.items[index];
    }
};
