const std = @import("std");
pub const log = @import("log.zig");
pub const fsutils = @import("fsutils.zig");
pub const simd = @import("simd.zig");

pub fn esc(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf2: std.ArrayList(u8) = .empty;
    defer buf2.deinit(allocator);
    for (s) |c| switch (c) {
        '&' => try buf2.appendSlice(allocator, "&amp;"),
        '<' => try buf2.appendSlice(allocator, "&lt;"),
        '>' => try buf2.appendSlice(allocator, "&gt;"),
        '"' => try buf2.appendSlice(allocator, "&quot;"),
        else => try buf2.append(allocator, c),
    };
    return try buf2.toOwnedSlice(allocator);
}

pub fn demerauLevenshteinDistance(
    allocator: std.mem.Allocator,
    s1: []const u8,
    s2: []const u8,
    max_distance: usize,
) !usize {
    const s1_len = s1.len;
    const s2_len = s2.len;

    if (s1_len == 0) return @min(s2_len, max_distance);
    if (s2_len == 0) return @min(s1_len, max_distance);

    const len_diff = if (s1_len > s2_len) s1_len - s2_len else s2_len - s1_len;
    if (len_diff > max_distance) {
        return max_distance;
    }

    const row_len = s2_len + 1;
    const total_needed = row_len * 3;

    var inline_buffer: [256]usize = undefined;
    const buffer = if (total_needed <= inline_buffer.len)
        inline_buffer[0..total_needed]
    else
        try allocator.alloc(usize, total_needed);

    defer if (total_needed > inline_buffer.len) allocator.free(buffer);

    var prev_prev = buffer[0..row_len];
    var prev = buffer[row_len .. row_len * 2];
    var curr = buffer[row_len * 2 .. total_needed];

    @memset(prev_prev, 0);
    for (0..row_len) |j| {
        prev[j] = j;
    }

    for (1..s1_len + 1) |i| {
        curr[0] = i;
        var row_min_distance = curr[0];

        for (1..row_len) |j| {
            const cost: usize = if (s1[i - 1] == s2[j - 1]) 0 else 1;

            var min_val = @min(
                prev[j] + 1,
                curr[j - 1] + 1,
                prev[j - 1] + cost,
            );

            if (i > 1 and j > 1 and
                s1[i - 2] == s2[j - 1] and
                s1[i - 1] == s2[j - 2])
            {
                min_val = @min(min_val, prev_prev[j - 2] + 1);
            }

            curr[j] = min_val;

            if (min_val < row_min_distance) {
                row_min_distance = min_val;
            }
        }

        if (row_min_distance > max_distance) {
            return max_distance;
        }

        const temp = prev_prev;
        prev_prev = prev;
        prev = curr;
        curr = temp;
    }

    const distance = prev[s2_len];
    return @min(distance, max_distance);
}

pub fn execute(cmd: []const u8, allocator: std.mem.Allocator) !void {
    var buf: [1024:0]u8 = undefined;

    if (cmd.len >= buf.len) {
        return error.CommandTooLong;
    }

    @memcpy(buf[0..cmd.len], cmd);
    buf[cmd.len] = 0;

    const argv = [_:null]?[*:0]const u8{
        "sh",
        "-c",
        @as([*:0]const u8, @ptrCast(&buf)),
        null,
    };

    const pid = std.os.linux.fork();
    if (std.os.linux.errno(pid) != .SUCCESS) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = std.os.linux.execve("/bin/sh", &argv, environ);
        std.os.linux.exit(1);
    }

    const thread_data = try allocator.create(ThreadData);
    thread_data.* = .{
        .pid = @as(i32, @intCast(pid)),
        .allocator = allocator,
    };

    const thread = std.Thread.spawn(.{}, reapChild, .{thread_data}) catch |err| {
        allocator.destroy(thread_data);
        var status: u32 = 0;
        _ = std.os.linux.waitpid(@as(i32, @intCast(pid)), &status, 0);
        return err;
    };
    thread.detach();
}

const ThreadData = struct {
    pid: i32,
    allocator: std.mem.Allocator,
};

fn reapChild(data: *ThreadData) void {
    var status: u32 = 0;
    _ = std.os.linux.waitpid(data.pid, &status, 0);
    data.allocator.destroy(data);
}

pub extern "c" var environ: [*:null]?[*:0]u8;

pub fn strcomp(key: []const u8, literal: []const u8) bool {
    return std.mem.eql(u8, key, literal);
}

pub const tool_arg_limit = 16;

pub fn toolPath(allocator: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return allocator.dupe(u8, name) catch null;
    }
    if (std.fs.selfExePathAlloc(allocator) catch null) |exe_path| {
        defer allocator.free(exe_path);
        if (std.fs.path.dirname(exe_path)) |exe_dir| {
            const candidate = std.fs.path.join(allocator, &.{ exe_dir, name }) catch return null;
            if (fileExists(candidate)) return candidate;
            allocator.free(candidate);
        }
    }
    if (std.c.getenv("ZENKAI_TOOLS")) |tools_dir_raw| {
        const tools_dir = std.mem.sliceTo(tools_dir_raw, 0);
        const candidate = std.fs.path.join(allocator, &.{ tools_dir, name }) catch return null;
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
    }
    if (std.c.getenv("PATH")) |path_raw| {
        const path = std.mem.sliceTo(path_raw, 0);
        var it = std.mem.splitScalar(u8, path, ':');
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fs.path.join(allocator, &.{ dir, name }) catch continue;
            if (fileExists(candidate)) return candidate;
            allocator.free(candidate);
        }
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    if (std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{})) |file| {
        std.Io.File.close(file, io);
        return true;
    } else |_| {
        return false;
    }
}

const ArgvC = struct {
    array: [tool_arg_limit + 1:null]?[*:0]const u8,
    owned: [][:0]u8,
};

fn buildArgvC(allocator: std.mem.Allocator, args: []const []const u8) !ArgvC {
    if (args.len == 0 or args.len > tool_arg_limit) return error.TooManyArgs;
    const owned = try allocator.alloc([:0]u8, args.len);
    var array: [tool_arg_limit + 1:null]?[*:0]const u8 = undefined;
    var count: usize = 0;
    errdefer {
        for (owned[0..count]) |arg_ptr| allocator.free(arg_ptr);
        allocator.free(owned);
    }
    for (args, 0..) |arg, i| {
        owned[i] = try allocator.dupeZ(u8, arg);
        count += 1;
        array[i] = owned[i].ptr;
    }
    array[args.len] = null;
    return .{ .array = array, .owned = owned };
}

fn deinitArgvC(allocator: std.mem.Allocator, argv: *ArgvC) void {
    for (argv.owned) |arg_ptr| allocator.free(arg_ptr);
    allocator.free(argv.owned);
}

fn forkExec(argv: *const [tool_arg_limit + 1:null]?[*:0]const u8) c_int {
    const pid = std.c.fork();
    if (pid == 0) {
        _ = std.c.execve(@ptrCast(argv[0].?), @as([*:null]const ?[*:0]const u8, @ptrCast(argv)), environ);
        std.c._exit(127);
    }
    return pid;
}

fn reapChildC(data: *ThreadData) void {
    var status: c_int = 0;
    _ = std.c.waitpid(data.pid, &status, 0);
    data.allocator.destroy(data);
}

pub fn spawnTool(name: []const u8, args: []const []const u8, allocator: std.mem.Allocator) !void {
    const tool = toolPath(allocator, name) orelse return error.ToolNotFound;
    defer allocator.free(tool);

    var full_args = std.ArrayList([]const u8).empty;
    defer full_args.deinit(allocator);
    try full_args.append(allocator, tool);
    for (args) |arg| {
        if (full_args.items.len >= tool_arg_limit) return error.TooManyArgs;
        try full_args.append(allocator, arg);
    }

    var argv = try buildArgvC(allocator, full_args.items);
    defer deinitArgvC(allocator, &argv);

    const pid = forkExec(&argv.array);
    if (pid < 0) return error.ForkFailed;

    const thread_data = try allocator.create(ThreadData);
    thread_data.* = .{ .pid = pid, .allocator = allocator };
    const thread = std.Thread.spawn(.{}, reapChildC, .{thread_data}) catch |err| {
        allocator.destroy(thread_data);
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        return err;
    };
    thread.detach();
}

pub fn runTool(name: []const u8, args: []const []const u8, out: []u8, allocator: std.mem.Allocator) !usize {
    const tool = toolPath(allocator, name) orelse return error.ToolNotFound;
    defer allocator.free(tool);

    var full_args = std.ArrayList([]const u8).empty;
    defer full_args.deinit(allocator);
    try full_args.append(allocator, tool);
    for (args) |arg| {
        if (full_args.items.len >= tool_arg_limit) return error.TooManyArgs;
        try full_args.append(allocator, arg);
    }

    var argv = try buildArgvC(allocator, full_args.items);
    defer deinitArgvC(allocator, &argv);

    var pipefd: [2]c_int = undefined;
    if (std.c.pipe(&pipefd) != 0) return error.PipeFailed;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipefd[0]);
        _ = std.c.close(pipefd[1]);
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = std.c.close(pipefd[0]);
        _ = std.c.dup2(pipefd[1], 1);
        _ = std.c.dup2(pipefd[1], 2);
        if (pipefd[1] != 1) _ = std.c.close(pipefd[1]);
        _ = std.c.execve(@ptrCast(argv.array[0].?), @as([*:null]const ?[*:0]const u8, @ptrCast(&argv.array)), environ);
        std.c._exit(127);
    }

    _ = std.c.close(pipefd[1]);

    var total: usize = 0;
    while (total < out.len) {
        const bytes = std.c.read(pipefd[0], out[total..].ptr, out.len - total);
        if (bytes <= 0) break;
        total += @intCast(bytes);
    }
    _ = std.c.close(pipefd[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    return total;
}
