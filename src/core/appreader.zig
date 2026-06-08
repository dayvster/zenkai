const std = @import("std");
const de = @import("desktopapp");
const dapp_parser = @import("dapp_parser");
const fsutils = @import("utils").fsutils;

pub const AppReader = struct {
    apps: std.ArrayList(de.DesktopApp),
    desktop_files: std.ArrayList([]const u8),
    desktop_files_checksum: u64,
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
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AppReader) void {
        self.apps.deinit(self.allocator);
        for (self.desktop_files.items) |p| self.allocator.free(p);
        self.desktop_files.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn load(self: *AppReader) !void {
        var new_files: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (new_files.items) |p| self.allocator.free(p);
            new_files.deinit(self.allocator);
        }

        const options = fsutils.ReadDirOptions{
            .extensions = &[_][]const u8{".desktop"},
            .recursive = true,
            .max_depth = 10,
        };

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
                const duped = try self.allocator.dupe(u8, file_path);
                errdefer self.allocator.free(duped);
                try new_files.append(self.allocator, duped);
            }
        }

        for (self.desktop_files.items) |p| self.allocator.free(p);
        self.desktop_files.deinit(self.allocator);
        self.desktop_files = new_files;
        self.computeChecksum();
    }

    pub fn scan(self: *AppReader) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.apps.clearRetainingCapacity();

        for (self.desktop_files.items) |file_path| {
            const content = try fsutils.readFile(self.arena.allocator(), file_path, 2 * 1024 * 1024);
            var app = dapp_parser.DappParser.parseDesktopFile(self.arena.allocator(), content) catch |err| switch (err) {
                error.NoDisplay => continue,
                else => |e| return e,
            };
            app.file_path = try self.arena.allocator().dupe(u8, file_path);
            try self.apps.append(self.allocator, app);
        }
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
};
