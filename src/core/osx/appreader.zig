const std = @import("std");
const de = @import("desktopapp");
const fsutils = @import("utils").fsutils;
const PlistParser = @import("parser.zig").PlistParser;
const InfoPlist = @import("plist.zig").InfoPlist;

pub const AppReader = struct {
    apps: std.ArrayList(de.DesktopApp),
    app_bundles: std.ArrayList([]const u8),
    app_bundles_checksum: u64,
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    const default_locations = [_][]const u8{
        "/Applications",
        "~/Applications",
        "/usr/local/Applications",
    };

    pub fn init(allocator: std.mem.Allocator) AppReader {
        return .{
            .apps = .empty,
            .app_bundles = .empty,
            .app_bundles_checksum = 0,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AppReader) void {
        self.apps.deinit(self.allocator);
        for (self.app_bundles.items) |p| self.allocator.free(p);
        self.app_bundles.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn load(self: *AppReader) !void {
        var new_bundles: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (new_bundles.items) |p| self.allocator.free(p);
            new_bundles.deinit(self.allocator);
        }

        const options = fsutils.ReadDirOptions{
            .extensions = &[_][]const u8{".app"},
            .recursive = true,
            .max_depth = 1,
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

            for (found.items) |bundle_path| {
                const basename = std.fs.path.basename(bundle_path);
                if (std.mem.indexOf(u8, basename, "Helper") != null or
                    std.mem.indexOf(u8, basename, "Updater") != null or
                    std.mem.indexOf(u8, basename, "Crashpad") != null or
                    std.mem.indexOf(u8, bundle_path, "/Frameworks/") != null or
                    std.mem.indexOf(u8, bundle_path, "/Contents/") != null)
                {
                    continue;
                }
                try new_bundles.append(self.allocator, try self.allocator.dupe(u8, bundle_path));
            }
        }

        for (self.app_bundles.items) |p| self.allocator.free(p);
        self.app_bundles.deinit(self.allocator);
        self.app_bundles = new_bundles;
        self.computeChecksum();
    }

    pub fn scan(self: *AppReader) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.apps.clearRetainingCapacity();

        for (self.app_bundles.items) |bundle_path| {
            const plist_path = try std.fs.path.join(self.arena.allocator(), &.{ bundle_path, "Contents", "Info.plist" });
            const content = fsutils.readFile(self.arena.allocator(), plist_path, 512 * 1024) catch |err| switch (err) {
                error.FileNotFound, error.AccessDenied => continue,
                else => |e| return e,
            };

            const plist_val = PlistParser.parse(self.arena.allocator(), content) catch continue;
            const dict = switch (plist_val) {
                .dict => |d| d,
                else => continue,
            };

            const info = InfoPlist.fromDict(self.arena.allocator(), dict) catch continue;

            var app = initDefaultDapp(self.arena.allocator());
            app.file_path = try self.arena.allocator().dupe(u8, bundle_path);

            if (info.display_name) |n| {
                app.name = n;
            } else if (info.name) |n| {
                app.name = n;
            } else {
                const base = std.fs.path.basename(bundle_path);
                app.name = if (std.mem.endsWith(u8, base, ".app")) base[0 .. base.len - 4] else base;
            }

            if (info.executable) |exec| {
                app.exec = try std.fs.path.join(self.arena.allocator(), &.{ bundle_path, "Contents", "MacOS", exec });
            }

            if (info.icon) |icon| {
                const icon_file = if (std.mem.endsWith(u8, icon, ".icns"))
                    icon
                else
                    try std.fmt.allocPrint(self.arena.allocator(), "{s}.icns", .{icon});
                app.icon = try std.fs.path.join(self.arena.allocator(), &.{ bundle_path, "Contents", "Resources", icon_file });
            }

            app.comment = info.info_string orelse info.copyright;

            try self.apps.append(self.allocator, app);
        }
    }

    fn computeChecksum(self: *AppReader) void {
        var hasher = std.hash.Wyhash.init(0xDEADBEEF);

        std.mem.sort([]const u8, self.app_bundles.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        for (self.app_bundles.items) |path| {
            hasher.update(path);
        }

        self.app_bundles_checksum = hasher.final();
    }
};

fn initDefaultDapp(allocator: std.mem.Allocator) de.DesktopApp {
    return de.DesktopApp{
        .name = "",
        .exec = null,
        .icon = null,
        .comment = null,
        .type = .Application,
        .extra = std.StringHashMap([]const u8).init(allocator),
    };
}
