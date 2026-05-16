const std = @import("std");
const de = @import("desktopapp");
const fsutils = @import("fsutils");

pub const desktopapp = de;

pub const AppReader = struct {
    apps: std.ArrayList(de.DesktopApp),
    desktop_files: std.ArrayList([]const u8),
    desktop_files_checksum: u64,
    last_scan_mtime: i128,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const default_locations = [_][]const u8{
        "/usr/share/applications",
        "/usr/local/share/applications",
        "~/.local/share/applications",
        "~/.local/share/flatpak/exports/share/applications",
        "/var/lib/flatpak/exports/share/applications",
        "/var/lib/flatpak/applications",
        "/run/host/var/lib/flatpak/exports/share/applications",
        "/var/lib/snapd/desktop/applications",
        "/run/host/var/lib/snapd/desktop/applications",
    };

    pub fn init(allocator: std.mem.Allocator) AppReader {
        return .{
            .apps = .empty,
            .desktop_files = .empty,
            .desktop_files_checksum = 0,
            .last_scan_mtime = 0,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AppReader) void {
        self.apps.deinit(self.allocator);
        self.desktop_files.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn load(self: *AppReader) !void {
        self.clear();

        const options = fsutils.ReadDirOptions{
            .extensions = &[_][]const u8{".desktop"},
            .recursive = true,
            .max_depth = 10,
        };

        var max_mtime: i128 = 0;

        for (default_locations) |loc| {
            var found = fsutils.readDir(self.allocator, loc, options) catch |err| {
                switch (err) {
                    error.FileNotFound, error.AccessDenied, error.NotDir => continue,
                    else => continue,
                }
            };
            defer {
                for (found.items) |p| self.allocator.free(p);
                found.deinit(self.allocator);
            }

            for (found.items) |file_path| {
                const content = try readFile(self.allocator, file_path);
                defer self.allocator.free(content);

                const mtime = try getFileMTime(file_path);
                if (mtime > max_mtime) max_mtime = mtime;

                const app = parseDesktopFile(self.arena.allocator(), content) catch |err| switch (err) {
                    error.NoDisplay => continue,
                    else => |e| return e,
                };

                try self.apps.append(self.allocator, app);
                try self.desktop_files.append(self.allocator, try self.arena.allocator().dupe(u8, file_path));
            }
        }

        self.last_scan_mtime = max_mtime;
        self.computeChecksum();
    }

    pub fn reload(self: *AppReader) !void {
        if (try self.hasChanged()) {
            try self.load();
        }
    }

    fn hasChanged(self: *AppReader) !bool {
        const options = fsutils.ReadDirOptions{
            .extensions = &[_][]const u8{".desktop"},
            .recursive = true,
            .max_depth = 10,
        };

        var new_files: std.ArrayList([]const u8) = .empty;
        defer {
            for (new_files.items) |p| self.allocator.free(p);
            new_files.deinit(self.allocator);
        }

        for (default_locations) |loc| {
            var found = fsutils.readDir(self.allocator, loc, options) catch |err| {
                switch (err) {
                    error.FileNotFound, error.AccessDenied, error.NotDir => continue,
                    else => continue,
                }
            };
            defer {
                for (found.items) |p| self.allocator.free(p);
                found.deinit(self.allocator);
            }
            for (found.items) |p| {
                try new_files.append(self.allocator, try self.allocator.dupe(u8, p));
            }
        }

        var hasher = std.hash.Wyhash.init(0xDEADBEEF);
        std.mem.sort([]const u8, new_files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        for (new_files.items) |p| hasher.update(p);

        if (hasher.final() != self.desktop_files_checksum) return true;

        for (self.desktop_files.items) |p| {
            const mtime = getFileMTime(p) catch continue;
            if (mtime > self.last_scan_mtime) return true;
        }

        return false;
    }

    pub fn getAll(self: *const AppReader) []const de.DesktopApp {
        return self.apps.items;
    }

    pub fn debugPrint(self: *const AppReader) void {
        for (self.apps.items) |app| {
            std.debug.print("• {s} | {s}\n", .{ app.name, app.exec });
        }
    }

    fn clear(self: *AppReader) void {
        self.apps.clearRetainingCapacity();
        self.desktop_files.clearRetainingCapacity();
        self.desktop_files_checksum = 0;
        self.last_scan_mtime = 0;
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
    }

    fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const cwd = std.Io.Dir.cwd();
        const file = try std.Io.Dir.openFile(cwd, io, path, .{});
        defer std.Io.File.close(file, io);

        const stat = try std.Io.Dir.statFile(cwd, io, path, .{});
        const size = @as(usize, @intCast(stat.size));
        if (size > 2 * 1024 * 1024) return error.FileTooBig;

        var buf: [4096]u8 = undefined;
        var reader = std.Io.File.Reader.init(file, io, &buf);
        return try reader.interface.readAlloc(allocator, size);
    }

    fn getFileMTime(path: []const u8) !i128 {
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
        const cwd = std.Io.Dir.cwd();
        const stat = try std.Io.Dir.statFile(cwd, io, path, .{});
        return @as(i128, stat.mtime.nanoseconds);
    }

    fn computeChecksum(self: *AppReader) void {
        var hasher = std.hash.Wyhash.init(0xDEADBEEF);

        std.mem.sort([]const u8, self.desktop_files.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (self.desktop_files.items) |path| {
            hasher.update(path);
        }

        self.desktop_files_checksum = hasher.final();
    }

    fn parseDesktopFile(allocator: std.mem.Allocator, content: []const u8) !de.DesktopApp {
        var name: []const u8 = "";
        var exec: []const u8 = "";
        var icon: ?[]const u8 = null;
        var no_display = false;

        var in_desktop_entry = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            if (trimmed[0] == '[') {
                in_desktop_entry = std.mem.eql(u8, trimmed, "[Desktop Entry]");
                continue;
            }

            if (!in_desktop_entry) continue;

            const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
            const key = trimmed[0..eq_pos];
            const value = trimmed[eq_pos + 1 ..];

            if (std.mem.indexOfScalar(u8, key, '[') != null) continue;

            if (std.mem.eql(u8, key, "Type") and !std.mem.eql(u8, value, "Application")) {
                in_desktop_entry = false;
                continue;
            }

            if (std.mem.eql(u8, key, "NoDisplay") and std.mem.eql(u8, value, "true")) {
                no_display = true;
            }

            if (std.mem.eql(u8, key, "Name")) name = try allocator.dupe(u8, value);
            if (std.mem.eql(u8, key, "Exec")) exec = try allocator.dupe(u8, value);
            if (std.mem.eql(u8, key, "Icon")) icon = if (value.len > 0) try allocator.dupe(u8, value) else null;
        }

        if (no_display) return error.NoDisplay;

        return de.DesktopApp{
            .name = if (name.len > 0) name else try allocator.dupe(u8, "(unnamed)"),
            .exec = if (exec.len > 0) exec else try allocator.dupe(u8, "(none)"),
            .icon = icon,
        };
    }
};
