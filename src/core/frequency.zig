const std = @import("std");
const log = @import("utils").log;
const fsutils = @import("utils").fsutils;

pub const Row = struct {
    name: []const u8,
    score: u32,
};

pub const file_name = "frequency.dat";

pub const FrequencyStore = struct {
    allocator: std.mem.Allocator,
    scores: std.StringHashMap(u32),
    dirty: bool,

    pub fn init(allocator: std.mem.Allocator) FrequencyStore {
        return .{
            .allocator = allocator,
            .scores = std.StringHashMap(u32).init(allocator),
            .dirty = false,
        };
    }

    pub fn deinit(self: *FrequencyStore) void {
        var it = self.scores.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.scores.deinit();
    }

    pub fn load(self: *FrequencyStore, dir_path: []const u8) void {
        const path = std.fs.path.join(self.allocator, &.{ dir_path, file_name }) catch return;
        defer self.allocator.free(path);

        const content = fsutils.readFile(self.allocator, path, 128 * 1024) catch return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = trimmed[0..eq];
            const val = std.fmt.parseInt(u32, trimmed[eq + 1 ..], 10) catch continue;
            if (key.len > 0) {
                const key_duped = self.allocator.dupe(u8, key) catch continue;
                self.scores.put(key_duped, val) catch {
                    self.allocator.free(key_duped);
                };
            }
        }
    }

    pub fn save(self: *FrequencyStore, dir_path: []const u8) void {
        if (!self.dirty) return;
        const path = std.fs.path.join(self.allocator, &.{ dir_path, file_name }) catch return;
        defer self.allocator.free(path);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var it = self.scores.iterator();
        while (it.next()) |entry| {
            const line = std.fmt.allocPrint(self.allocator, "{s}={d}\n", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
            defer self.allocator.free(line);
            buf.appendSlice(self.allocator, line) catch return;
        }

        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const cwd = std.Io.Dir.cwd();
        var file = std.Io.Dir.createFile(cwd, io, path, .{}) catch {
            log.info("failed to save frequency data", .{});
            return;
        };
        defer std.Io.File.close(file, io);
        file.writeStreamingAll(io, buf.items) catch {
            log.info("failed to write frequency data", .{});
        };
        self.dirty = false;
    }

    pub fn increment(self: *FrequencyStore, key: []const u8) void {
        if (self.scores.getPtr(key)) |count| {
            count.* += 1;
            self.dirty = true;
            return;
        }
        const key_duped = self.allocator.dupe(u8, key) catch return;
        self.scores.put(key_duped, 1) catch {
            self.allocator.free(key_duped);
        };
        self.dirty = true;
    }

    pub fn getScore(self: *FrequencyStore, key: []const u8) u32 {
        return self.scores.get(key) orelse 0;
    }
};
