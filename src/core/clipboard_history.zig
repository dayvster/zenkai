//! Clipboard history for the background service: the text you copied, newest first. Pinned
//! entries stay until you unpin or delete them; the rest are capped at `max_unpinned`.
//!
//! Saved to $XDG_STATE_HOME/zenkai/clipboard-history.json (~/.local/state by default), not
//! next to zenkai.conf, so it doesn't end up in a dotfiles repository. Only you can read it.

const std = @import("std");
const log = @import("utils").log;
const Entry = @import("plugins").ClipboardEntry;

pub const max_unpinned = 200;
/// Copies larger than this are left out rather than cut short.
pub const max_text_bytes = 100 * 1024;

const file_version = 1;

const Saved = struct {
    version: u32,
    entries: []const SavedEntry,
};

const SavedEntry = struct {
    text: []const u8,
    pinned: bool = false,
    copied_at: i64 = 0,
};

pub const History = struct {
    allocator: std.mem.Allocator,
    /// Newest first. Each entry owns its text.
    entries: std.ArrayList(Entry) = .empty,
    next_id: u64 = 1,
    /// Where it's saved; null keeps it in memory only, as tests do.
    path: ?[]const u8 = null,

    /// Loads the saved history, or starts an empty one when there's none or it can't be read.
    pub fn load(allocator: std.mem.Allocator) History {
        var history: History = .{ .allocator = allocator, .path = historyPath(allocator) catch null };
        const path = history.path orelse return history;
        const content = @import("utils").fsutils.readFile(allocator, path, 64 * 1024 * 1024) catch return history;
        defer allocator.free(content);
        const parsed = std.json.parseFromSlice(Saved, allocator, content, .{ .ignore_unknown_fields = true }) catch |err| {
            log.info("clipboard history: can't read {s}: {}", .{ path, err });
            return history;
        };
        defer parsed.deinit();
        if (parsed.value.version != file_version) return history;
        for (parsed.value.entries) |saved| {
            const text = allocator.dupe(u8, saved.text) catch break;
            history.entries.append(allocator, .{ .id = history.takeId(), .text = text, .pinned = saved.pinned, .copied_at = saved.copied_at }) catch {
                allocator.free(text);
                break;
            };
        }
        return history;
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |entry| self.allocator.free(entry.text);
        self.entries.deinit(self.allocator);
        if (self.path) |path| self.allocator.free(path);
    }

    /// Records a copy. Copying something already in the history moves it to the top instead
    /// of adding it twice. Blank and oversized copies are ignored, and so is anything that
    /// isn't UTF-8 text, such as UTF-16 or binary data offered under a text type.
    pub fn add(self: *History, text: []const u8, now: i64) void {
        if (std.mem.trim(u8, text, " \t\r\n").len == 0 or text.len > max_text_bytes) return;
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return;
        for (self.entries.items, 0..) |entry, i| {
            if (!std.mem.eql(u8, entry.text, text)) continue;
            var moved = self.entries.orderedRemove(i);
            moved.copied_at = now;
            self.entries.insertAssumeCapacity(0, moved);
            self.save();
            return;
        }
        const owned = self.allocator.dupe(u8, text) catch return;
        self.entries.insert(self.allocator, 0, .{ .id = self.takeId(), .text = owned, .copied_at = now }) catch {
            self.allocator.free(owned);
            return;
        };
        self.dropOldest();
        self.save();
    }

    pub fn setPinned(self: *History, id: u64, pinned: bool) bool {
        const entry = self.find(id) orelse return false;
        entry.pinned = pinned;
        self.dropOldest();
        self.save();
        return true;
    }

    pub fn remove(self: *History, id: u64) bool {
        for (self.entries.items, 0..) |entry, i| {
            if (entry.id != id) continue;
            self.allocator.free(entry.text);
            _ = self.entries.orderedRemove(i);
            self.save();
            return true;
        }
        return false;
    }

    /// Removes everything except pinned entries, which were kept on purpose.
    pub fn clearUnpinned(self: *History) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.pinned) {
                i += 1;
                continue;
            }
            self.allocator.free(entry.text);
            _ = self.entries.orderedRemove(i);
        }
        self.save();
    }

    fn find(self: *History, id: u64) ?*Entry {
        for (self.entries.items) |*entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn takeId(self: *History) u64 {
        defer self.next_id += 1;
        return self.next_id;
    }

    /// Drops the oldest unpinned entries beyond the cap.
    fn dropOldest(self: *History) void {
        var unpinned: usize = 0;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            const entry = self.entries.items[i];
            if (entry.pinned) {
                i += 1;
                continue;
            }
            unpinned += 1;
            if (unpinned <= max_unpinned) {
                i += 1;
                continue;
            }
            self.allocator.free(entry.text);
            _ = self.entries.orderedRemove(i);
        }
    }

    /// Writes a new file and renames it over the old one, so a crash mid-write never leaves
    /// a cut-off history. The file is created readable by its owner only.
    fn save(self: *History) void {
        const path = self.path orelse return;
        const saved = self.allocator.alloc(SavedEntry, self.entries.items.len) catch return;
        defer self.allocator.free(saved);
        for (self.entries.items, saved) |entry, *out| out.* = .{ .text = entry.text, .pinned = entry.pinned, .copied_at = entry.copied_at };
        const json = std.json.Stringify.valueAlloc(self.allocator, Saved{ .version = file_version, .entries = saved }, .{}) catch return;
        defer self.allocator.free(json);

        const tmp = std.fmt.allocPrintSentinel(self.allocator, "{s}.tmp", .{path}, 0) catch return;
        defer self.allocator.free(tmp);
        const dest = self.allocator.dupeSentinel(u8, path, 0) catch return;
        defer self.allocator.free(dest);
        const fd = std.c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
        if (fd < 0) {
            log.info("clipboard history: can't write {s}", .{tmp});
            return;
        }
        var written: usize = 0;
        while (written < json.len) {
            const n = std.c.write(fd, json[written..].ptr, json.len - written);
            if (n <= 0) break;
            written += @intCast(n);
        }
        _ = std.c.close(fd);
        if (written != json.len or std.c.rename(tmp, dest) != 0) {
            log.info("clipboard history: can't save {s}", .{path});
            _ = std.c.unlink(tmp);
        }
    }
};

/// $XDG_STATE_HOME/zenkai/clipboard-history.json, creating the folder (owner only) if needed.
fn historyPath(allocator: std.mem.Allocator) ![]const u8 {
    const state_dir = if (std.c.getenv("XDG_STATE_HOME")) |dir|
        try allocator.dupe(u8, std.mem.span(dir))
    else if (std.c.getenv("HOME")) |home|
        try std.fmt.allocPrint(allocator, "{s}/.local/state", .{std.mem.span(home)})
    else
        return error.NoHome;
    defer allocator.free(state_dir);
    const dir = try std.fmt.allocPrintSentinel(allocator, "{s}/zenkai", .{state_dir}, 0);
    defer allocator.free(dir);
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    try @import("utils").fsutils.makeDir(io, state_dir);
    _ = std.c.mkdir(dir, 0o700);
    return std.fmt.allocPrint(allocator, "{s}/clipboard-history.json", .{dir});
}

test "copies are kept newest first, without duplicates" {
    var history: History = .{ .allocator = std.testing.allocator };
    defer history.deinit();
    history.add("one", 1);
    history.add("two", 2);
    history.add("   ", 3);
    history.add("one", 4);
    try std.testing.expectEqual(@as(usize, 2), history.entries.items.len);
    try std.testing.expectEqualStrings("one", history.entries.items[0].text);
    try std.testing.expectEqual(@as(i64, 4), history.entries.items[0].copied_at);
    try std.testing.expectEqualStrings("two", history.entries.items[1].text);
}

test "pinned entries survive the cap and clearing" {
    var history: History = .{ .allocator = std.testing.allocator };
    defer history.deinit();
    history.add("keep me", 0);
    try std.testing.expect(history.setPinned(history.entries.items[0].id, true));
    var buf: [16]u8 = undefined;
    for (0..max_unpinned + 5) |i| history.add(try std.fmt.bufPrint(&buf, "copy {d}", .{i}), @intCast(i + 1));
    try std.testing.expectEqual(@as(usize, max_unpinned + 1), history.entries.items.len);
    try std.testing.expectEqualStrings("copy 204", history.entries.items[0].text);

    history.clearUnpinned();
    try std.testing.expectEqual(@as(usize, 1), history.entries.items.len);
    try std.testing.expectEqualStrings("keep me", history.entries.items[0].text);
    try std.testing.expect(history.remove(history.entries.items[0].id));
    try std.testing.expectEqual(@as(usize, 0), history.entries.items.len);
}

test "only UTF-8 text is kept" {
    var history: History = .{ .allocator = std.testing.allocator };
    defer history.deinit();
    history.add("h\x00t\x00t\x00p\x00", 1);
    history.add("\xff\xfe broken", 2);
    history.add("caf\xc3\xa9", 3);
    try std.testing.expectEqual(@as(usize, 1), history.entries.items.len);
    try std.testing.expectEqualStrings("café", history.entries.items[0].text);
}

test "oversized copies are left out" {
    var history: History = .{ .allocator = std.testing.allocator };
    defer history.deinit();
    const big = try std.testing.allocator.alloc(u8, max_text_bytes + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    history.add(big, 1);
    try std.testing.expectEqual(@as(usize, 0), history.entries.items.len);
}
