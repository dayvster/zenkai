const std = @import("std");
const de = @import("desktopapp");

const getapps_bin = @embedFile("../../../external/getapps.exe");

pub const AppReader = struct {
    apps: std.ArrayList(de.DesktopApp),
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator) AppReader {
        return .{
            .apps = .empty,
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *AppReader) void {
        self.apps.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn load(_: *AppReader) !void {}

    pub fn scan(self: *AppReader) !void {
        self.arena.deinit();
        self.arena = std.heap.ArenaAllocator.init(self.allocator);
        self.apps.clearRetainingCapacity();

        const tmp_exe = blk: {
            const dir = std.fs.getTempDir();
            const f = dir.createFile("zenkai-getapps-XXXXXX.exe", .{ .read = true }) catch |err| {
                std.log.err("failed to create temp file for getapps.exe: {s}", .{@errorName(err)});
                return error.ExtractFailed;
            };
            const name = try f.name();
            _ = try f.write(getapps_bin);
            f.close();
            break :blk name;
        };
        defer std.fs.deleteFileAbsolute(tmp_exe) catch {};

        const output = run: {
            var proc = std.ChildProcess.init(&.{tmp_exe}, self.arena.allocator());
            proc.stdout_behavior = .Pipe;
            proc.stderr_behavior = .Ignore;
            proc.spawn() catch |err| {
                std.log.err("failed to spawn getapps.exe: {s}", .{@errorName(err)});
                return error.SpawnFailed;
            };

            const out = proc.readAllAlloc(self.arena.allocator(), 8 * 1024 * 1024) catch |err| {
                _ = proc.kill() catch {};
                std.log.err("failed to read getapps.exe output: {s}", .{@errorName(err)});
                return error.ReadFailed;
            };

            const term = proc.wait() catch |err| {
                std.log.err("failed to wait for getapps.exe: {s}", .{@errorName(err)});
                return error.WaitFailed;
            };

            switch (term) {
                .Exited => |code| if (code != 0) {
                    std.log.err("getapps.exe exited with code {d}", .{code});
                    return error.NonZeroExit;
                },
                else => {
                    std.log.err("getapps.exe terminated abnormally", .{});
                    return error.AbnormalExit;
                },
            }

            break :run out;
        };

        if (output.len == 0) return;

        const parsed = std.json.parseFromSlice([]const WinAppJson, self.arena.allocator(), output, .{ .allocate = .alloc_always }) catch |err| {
            std.log.err("failed to parse getapps.exe JSON output: {s}", .{@errorName(err)});
            return error.ParseFailed;
        };

        for (parsed.value) |winapp| {
            if (winapp.name.len == 0) continue;

            var app = initDefaultDapp(self.arena.allocator());
            app.name = winapp.name;
            app.exec = winapp.exec;
            app.try_exec = winapp.try_exec;
            app.icon = winapp.icon;
            app.comment = winapp.comment;
            app.path = winapp.install_path;
            app.url = winapp.url;
            app.no_display = winapp.no_display;
            app.hidden = winapp.hidden;

            if (winapp.categories) |cats| {
                app.categories = try self.arena.allocator().alloc([]const u8, cats.len);
                for (cats, app.categories) |c, *dst| dst.* = c;
            }

            try self.apps.append(self.allocator, app);
        }
    }
};

const WinAppJson = struct {
    type: []const u8,
    name: []const u8,
    version: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    try_exec: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    install_path: ?[]const u8 = null,
    url: ?[]const u8 = null,
    categories: ?[]const []const u8 = null,
    no_display: bool = false,
    hidden: bool = false,
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
