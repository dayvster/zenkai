const std = @import("std");
const de = @import("desktopapp");
const fsutils = @import("utils").fsutils;
const log = @import("utils").log;
const debug = @import("../../debug/debug.zig");
const appsfolder = @import("appsfolder.zig");
const shell_icon_prefix = "windows-shell:";
const appsfolder_icon_prefix = "windows-app:";

fn endsWithIgnoreCase(text: []const u8, suffix: []const u8) bool {
    return text.len >= suffix.len and std.ascii.eqlIgnoreCase(text[text.len - suffix.len ..], suffix);
}

fn attributeValue(tag: []const u8, attribute_name: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, tag, search_from, attribute_name)) |index| {
        search_from = index + attribute_name.len;
        if (index > 0 and !std.ascii.isWhitespace(tag[index - 1])) continue;
        var value_start = search_from;
        while (value_start < tag.len and std.ascii.isWhitespace(tag[value_start])) : (value_start += 1) {}
        if (value_start >= tag.len or tag[value_start] != '=') continue;
        value_start += 1;
        while (value_start < tag.len and std.ascii.isWhitespace(tag[value_start])) : (value_start += 1) {}
        if (value_start >= tag.len or (tag[value_start] != '"' and tag[value_start] != '\'')) continue;
        const quote = tag[value_start];
        value_start += 1;
        const value_end = std.mem.indexOfScalarPos(u8, tag, value_start, quote) orelse return null;
        return tag[value_start..value_end];
    }
    return null;
}

fn pathExists(path: []const u8) bool {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn resolvePackageLogo(allocator: std.mem.Allocator, package_path: []const u8, app_id: []const u8) ?[]const u8 {
    if (package_path.len == 0) return null;
    const manifest_path = std.fmt.allocPrint(allocator, "{s}\\AppxManifest.xml", .{package_path}) catch return null;
    const manifest = fsutils.readFile(allocator, manifest_path, 4 * 1024 * 1024) catch return null;
    const app_id_suffix = if (std.mem.lastIndexOfScalar(u8, app_id, '!')) |bang| app_id[bang + 1 ..] else app_id;

    var app_start: usize = 0;
    while (std.mem.indexOfPos(u8, manifest, app_start, "<Application")) |start| {
        const tag_end = std.mem.indexOfScalarPos(u8, manifest, start, '>') orelse return null;
        const application_tag = manifest[start .. tag_end + 1];
        app_start = tag_end + 1;
        if (attributeValue(application_tag, "Id")) |id| {
            if (!std.mem.eql(u8, id, app_id_suffix)) continue;
            const app_end = std.mem.indexOfPos(u8, manifest, app_start, "</Application>") orelse manifest.len;
            const application_body = manifest[app_start..app_end];
            const visual_start = std.mem.indexOf(u8, application_body, "VisualElements") orelse return null;
            const visual_tag_start = std.mem.lastIndexOfScalar(u8, application_body[0..visual_start], '<') orelse return null;
            const visual_tag_end_rel = std.mem.indexOfScalarPos(u8, application_body, visual_start, '>') orelse return null;
            const visual_tag = application_body[visual_tag_start .. visual_tag_end_rel + 1];
            const logo = attributeValue(visual_tag, "Square44x44Logo") orelse attributeValue(visual_tag, "Square150x150Logo") orelse return null;
            if (std.mem.startsWith(u8, logo, "ms-resource:")) return null;

            const relative_logo = allocator.dupe(u8, logo) catch return null;
            for (relative_logo) |*char| if (char.* == '/') {
                char.* = '\\';
            };
            const direct_path = std.fs.path.join(allocator, &.{ package_path, relative_logo }) catch return null;
            if (pathExists(direct_path)) return direct_path;

            const logo_dir = std.fs.path.dirname(direct_path) orelse return null;
            const logo_base = std.fs.path.basename(direct_path);
            const extension_start = std.mem.lastIndexOfScalar(u8, logo_base, '.') orelse logo_base.len;
            const logo_stem = logo_base[0..extension_start];
            const suffixes = [_][]const u8{
                ".scale-100.png",
                ".scale-200.png",
                ".targetsize-32.png",
                ".targetsize-44.png",
                ".targetsize-48.png",
                ".png",
            };
            for (suffixes) |suffix| {
                const candidate = std.fmt.allocPrint(allocator, "{s}\\{s}{s}", .{ logo_dir, logo_stem, suffix }) catch continue;
                if (pathExists(candidate)) return candidate;
            }
        }
    }
    return null;
}

/// Reads the shortcuts Windows exposes in the per-user and shared Start Menu.
/// ShellExecute resolves the shortcut when an item is selected.
pub const AppReader = struct {
    apps: std.ArrayList(de.DesktopApp),
    shortcuts: std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) AppReader {
        return .{
            .apps = .empty,
            .shortcuts = .empty,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AppReader) void {
        self.apps.deinit(self.allocator);
        for (self.shortcuts.items) |path| self.allocator.free(path);
        self.shortcuts.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn load(self: *AppReader) !void {
        var found_paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (found_paths.items) |path| self.allocator.free(path);
            found_paths.deinit(self.allocator);
        }
        const options: fsutils.ReadDirOptions = .{
            .extensions = &.{ ".lnk", ".url" },
            .recursive = true,
            .max_depth = 8,
        };
        const env_names = [_][]const u8{ "APPDATA", "PROGRAMDATA" };
        for (env_names) |env_name| {
            const env_name_z = try self.allocator.dupeZ(u8, env_name);
            defer self.allocator.free(env_name_z);
            const raw = std.c.getenv(env_name_z) orelse continue;
            const base = std.mem.sliceTo(raw, 0);
            const start_menu = try std.fs.path.join(self.allocator, &.{ base, "Microsoft", "Windows", "Start Menu", "Programs" });
            defer self.allocator.free(start_menu);
            var paths = fsutils.readDir(self.allocator, start_menu, options) catch continue;
            defer {
                for (paths.items) |path| self.allocator.free(path);
                paths.deinit(self.allocator);
            }
            for (paths.items) |path| {
                const basename = std.fs.path.basename(path);
                if (!endsWithIgnoreCase(basename, ".lnk") and
                    !endsWithIgnoreCase(basename, ".url")) continue;
                try found_paths.append(self.allocator, try self.allocator.dupe(u8, path));
            }
        }

        for (self.shortcuts.items) |path| self.allocator.free(path);
        self.shortcuts.deinit(self.allocator);
        self.shortcuts = found_paths;
    }

    pub fn scan(self: *AppReader) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.apps.clearRetainingCapacity();
        const arena = self.arena.allocator();
        for (self.shortcuts.items) |path| {
            const basename = std.fs.path.basename(path);
            const extension_len: usize = if (endsWithIgnoreCase(basename, ".lnk")) 4 else if (endsWithIgnoreCase(basename, ".url")) 4 else 0;
            if (basename.len <= extension_len) continue;
            const name = try arena.dupe(u8, basename[0 .. basename.len - extension_len]);
            const app = de.DesktopEntry{
                .name = name,
                .type = .Application,
                .exec = try std.fmt.allocPrint(arena, "\"{s}\"", .{path}),
                .file_path = try arena.dupe(u8, path),
                .icon = try std.fmt.allocPrint(arena, "{s}{s}", .{ shell_icon_prefix, path }),
                .extra = std.StringHashMap([]const u8).init(arena),
            };
            try self.apps.append(self.allocator, app);
        }

        const appsfolder_started = debug.monotonicNs();
        const start_apps = appsfolder.enumerate(arena, self.apps.items) catch |err| {
            log.info("Windows AppsFolder scan failed: {}", .{err});
            return;
        };
        const appsfolder_elapsed = debug.monotonicNs() - appsfolder_started;
        const apps_before_merge = self.apps.items.len;
        const package_icons_started = debug.monotonicNs();
        for (start_apps) |start_app| {
            if (start_app.name.len == 0) continue;

            const exec = if (start_app.target_path.len > 0)
                try std.fmt.allocPrint(arena, "\"{s}\"", .{start_app.target_path})
            else
                try std.fmt.allocPrint(arena, "\"explorer.exe\" shell:AppsFolder\\{s}", .{start_app.app_id});
            const icon = if (start_app.target_path.len > 0)
                try std.fmt.allocPrint(arena, "{s}{s}", .{ shell_icon_prefix, start_app.target_path })
            else if (resolvePackageLogo(arena, start_app.package_path, start_app.app_id)) |logo|
                logo
            else
                try std.fmt.allocPrint(arena, "{s}{s}", .{ appsfolder_icon_prefix, start_app.app_id });

            try self.apps.append(self.allocator, .{
                .name = start_app.name,
                .type = .Application,
                .exec = exec,
                .icon = icon,
                .extra = std.StringHashMap([]const u8).init(arena),
            });
        }
        log.info("Start Menu: {d} shortcuts; AppsFolder: {d} additional apps", .{
            apps_before_merge,
            self.apps.items.len - apps_before_merge,
        });
        log.info("AppsFolder enumeration {d:.2}ms; package icons {d:.2}ms", .{
            @as(f64, @floatFromInt(appsfolder_elapsed)) / std.time.ns_per_ms,
            @as(f64, @floatFromInt(debug.monotonicNs() - package_icons_started)) / std.time.ns_per_ms,
        });
    }
};
