const std = @import("std");
const builtin = @import("builtin");
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

    const pid = std.c.fork();
    if (pid < 0) {
        return error.ForkFailed;
    }

    if (pid == 0) {
        _ = std.c.execve("/bin/sh", &argv, environ);
        std.c._exit(1);
    }

    const thread_data = try allocator.create(ThreadData);
    thread_data.* = .{
        .pid = @as(i32, @intCast(pid)),
        .allocator = allocator,
    };

    const thread = std.Thread.spawn(.{}, reapChild, .{thread_data}) catch |err| {
        allocator.destroy(thread_data);
        var status: u32 = 0;
        _ = std.c.waitpid(@as(i32, @intCast(pid)), &status, 0);
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
    _ = std.c.waitpid(data.pid, &status, 0);
    data.allocator.destroy(data);
}

pub fn resolveExecutable(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return error.NotFound;
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (fileExists(name)) return try allocator.dupe(u8, name);
        return error.NotFound;
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
    return error.NotFound;
}

fn findBundleDir(path: []const u8) ?[]const u8 {
    var end = path.len;
    while (end > 0) {
        const slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/');
        const dir_start = slash orelse 0;
        if (std.mem.endsWith(u8, path[dir_start..end], ".app")) return path[dir_start..end];
        if (slash == null) return null;
        end = slash.?;
    }
    return null;
}

pub fn executeArgv(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    if (argv.len == 0) return error.NoExecutable;
    const exe = try resolveExecutable(allocator, argv[0]);
    defer allocator.free(exe);

    var final = std.ArrayList([]const u8).empty;
    defer final.deinit(allocator);
    try final.append(allocator, exe);
    if (builtin.os.tag == .macos) {
        if (findBundleDir(exe)) |bundle| {
            final.clearRetainingCapacity();
            try final.append(allocator, "/usr/bin/open");
            try final.append(allocator, bundle);
            try final.append(allocator, "--args");
        }
    }
    for (argv[1..]) |arg| try final.append(allocator, arg);

    try spawnTool(final.items[0], final.items[1..], allocator);
}

// Splits an Exec value into arguments following the freedesktop Desktop Entry
// specification (section "The Exec key", as of 1.5):
//   - arguments are separated by spaces (tabs also accepted as separators)
//   - double quotes group an argument and preserve whitespace; inside double
//     quotes only ", \, ` and $ are unescaped when preceded by a backslash
//   - single quotes and backslashes outside double quotes are LITERAL
//     characters (no shell-style single quoting, no shell expansion)
//   - an unterminated double quote is treated as an error
pub fn tokenizeCommandLine(allocator: std.mem.Allocator, input: []const u8) ![]const []const u8 {
    var tokens = std.ArrayList([]const u8).empty;
    errdefer {
        for (tokens.items) |t| allocator.free(t);
        tokens.deinit(allocator);
    }

    var i: usize = 0;
    while (i < input.len) {
        while (i < input.len and (input[i] == ' ' or input[i] == '\t')) i += 1;
        if (i >= input.len) break;

        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        var tok_started = false;

        while (i < input.len) {
            const c = input[i];
            if (c == ' ' or c == '\t') {
                i += 1;
                break;
            }
            tok_started = true;
            if (c == '"') {
                i += 1;
                while (i < input.len and input[i] != '"') {
                    if (input[i] == '\\' and i + 1 < input.len and
                        (input[i + 1] == '"' or input[i + 1] == '\\' or input[i + 1] == '$' or
                            input[i + 1] == '`'))
                    {
                        i += 1;
                    }
                    try buf.append(allocator, input[i]);
                    i += 1;
                }
                if (i >= input.len) return error.InvalidSyntax;
                i += 1;
            } else {
                try buf.append(allocator, c);
                i += 1;
            }
        }

        // An explicitly quoted empty argument is kept as an empty token;
        // separators alone never produce empty tokens.
        if (tok_started) {
            try tokens.append(allocator, try buf.toOwnedSlice(allocator));
        }
    }

    return try tokens.toOwnedSlice(allocator);
}

fn nowNs() u64 {
    var ts: std.c.timespec = std.mem.zeroes(std.c.timespec);
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    if (std.process.executableDirPathAlloc(io, allocator) catch null) |exe_dir| {
        defer allocator.free(exe_dir);
        const candidate = std.fs.path.join(allocator, &.{ exe_dir, name }) catch return null;
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);
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

pub const RunResult = struct {
    bytes: usize,
    truncated: bool,
};

const POLL_IN: i16 = 0x1;
const POLL_HUP: i16 = 0x10;

pub fn runToolTimed(name: []const u8, args: []const []const u8, out: []u8, timeout_ms: u64, allocator: std.mem.Allocator) !RunResult {
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
        _ = std.c.setpgid(0, 0);
        _ = std.c.close(pipefd[0]);
        _ = std.c.dup2(pipefd[1], 1);
        if (pipefd[1] != 1) _ = std.c.close(pipefd[1]);
        _ = std.c.execve(@ptrCast(argv.array[0].?), @as([*:null]const ?[*:0]const u8, @ptrCast(&argv.array)), environ);
        std.c._exit(127);
    }

    _ = std.c.close(pipefd[1]);

    var total: usize = 0;
    var truncated = false;
    var timed_out = false;
    var scratch: [256]u8 = undefined;
    const deadline = nowNs() + timeout_ms * std.time.ns_per_ms;

    while (true) {
        const now = nowNs();
        if (now >= deadline) {
            timed_out = true;
            break;
        }
        var pollfd = std.c.pollfd{
            .fd = pipefd[0],
            .events = POLL_IN,
            .revents = 0,
        };
        const remaining_ms: i32 = @intCast(@min((deadline - now) / std.time.ns_per_ms, 999));
        const pr = std.c.poll(&pollfd, 1, remaining_ms);
        if (pr < 0) break;
        if (pr == 0) continue;

        if ((pollfd.revents & (POLL_IN | POLL_HUP)) == 0) continue;
        if (total < out.len) {
            const n = std.c.read(pipefd[0], out[total..].ptr, out.len - total);
            if (n <= 0) break;
            total += @intCast(n);
        } else {
            truncated = true;
            const n = std.c.read(pipefd[0], scratch.ptr, scratch.len);
            if (n <= 0) break;
        }
    }

    // The child runs in its own process group (setpgid above), so killing the
    // negative pid also terminates any descendants it spawned. If the process
    // group is already gone kill(-pid) simply fails harmlessly.
    if (timed_out) _ = std.c.kill(-pid, 9);
    _ = std.c.close(pipefd[0]);

    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);

    if (timed_out) return error.RunTimeout;
    return .{ .bytes = total, .truncated = truncated };
}

test "utils: findBundleDir detects .app bundles for macOS launching" {
    try std.testing.expectEqualStrings("/Applications/Foo.app", findBundleDir("/Applications/Foo.app/Contents/MacOS/foo").?);
    try std.testing.expectEqualStrings("/Applications/Foo.app", findBundleDir("/Applications/Foo.app/Contents/Frameworks/lib.dylib").?);
    try std.testing.expectEqualStrings("/Applications/A.app/Contents/Resources/B.app", findBundleDir("/Applications/A.app/Contents/Resources/B.app/Contents/MacOS/b").?);
    try std.testing.expect(findBundleDir("/usr/bin/foo") == null);
    try std.testing.expect(findBundleDir("plain") == null);
}

test "utils: executeArgv surfaces an error instead of falling back to a shell" {
    const allocator = std.testing.allocator;
    const argv = [_][]const u8{"/definitely-not-a-real-zenkai-test-binary"};
    try std.testing.expectError(error.NotFound, executeArgv(allocator, &argv));
}

test "utils: tokenizeCommandLine follows Exec grammar (double quotes only)" {
    const allocator = std.testing.allocator;

    {
        const input = "foo \"bar baz\" \"a\\\"b\" plain";
        const tokens = try tokenizeCommandLine(allocator, input);
        defer {
            for (tokens) |t| allocator.free(t);
            allocator.free(tokens);
        }
        try std.testing.expectEqual(@as(usize, 4), tokens.len);
        try std.testing.expectEqualStrings("foo", tokens[0]);
        try std.testing.expectEqualStrings("bar baz", tokens[1]);
        try std.testing.expectEqualStrings("a\"b", tokens[2]);
        try std.testing.expectEqualStrings("plain", tokens[3]);
    }

    {
        const input = "sh -c \"echo \\$HOME\"";
        const tokens = try tokenizeCommandLine(allocator, input);
        defer {
            for (tokens) |t| allocator.free(t);
            allocator.free(tokens);
        }
        try std.testing.expectEqual(@as(usize, 3), tokens.len);
        try std.testing.expectEqualStrings("sh", tokens[0]);
        try std.testing.expectEqualStrings("-c", tokens[1]);
        try std.testing.expectEqualStrings("echo $HOME", tokens[2]);
    }
}

test "utils: tokenizeCommandLine treats single quotes and backslashes as literal (Exec grammar)" {
    const allocator = std.testing.allocator;

    const input = "app 'single quoted' a\\ b";
    const tokens = try tokenizeCommandLine(allocator, input);
    defer {
        for (tokens) |t| allocator.free(t);
        allocator.free(tokens);
    }

    try std.testing.expectEqual(@as(usize, 5), tokens.len);
    try std.testing.expectEqualStrings("app", tokens[0]);
    try std.testing.expectEqualStrings("'single", tokens[1]);
    try std.testing.expectEqualStrings("quoted'", tokens[2]);
    try std.testing.expectEqualStrings("a\\", tokens[3]);
    try std.testing.expectEqualStrings("b", tokens[4]);
}

test "utils: tokenizeCommandLine rejects an unterminated double quote" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidSyntax, tokenizeCommandLine(allocator, "app \"unclosed"));
}

test "utils: tokenizeCommandLine collapses separators without empty tokens" {
    const allocator = std.testing.allocator;

    const input = "   one   two\t  three  ";
    const tokens = try tokenizeCommandLine(allocator, input);
    defer {
        for (tokens) |t| allocator.free(t);
        allocator.free(tokens);
    }
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("one", tokens[0]);
    try std.testing.expectEqualStrings("two", tokens[1]);
    try std.testing.expectEqualStrings("three", tokens[2]);
}

test "utils: tokenizeCommandLine preserves an explicitly quoted empty argument" {
    const allocator = std.testing.allocator;

    const input = "a \"\" b";
    const tokens = try tokenizeCommandLine(allocator, input);
    defer {
        for (tokens) |t| allocator.free(t);
        allocator.free(tokens);
    }
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqualStrings("a", tokens[0]);
    try std.testing.expectEqualStrings("", tokens[1]);
    try std.testing.expectEqualStrings("b", tokens[2]);

    const input2 = "x \"\"";
    const tokens2 = try tokenizeCommandLine(allocator, input2);
    defer {
        for (tokens2) |t| allocator.free(t);
        allocator.free(tokens2);
    }
    try std.testing.expectEqual(@as(usize, 2), tokens2.len);
    try std.testing.expectEqualStrings("x", tokens2[0]);
    try std.testing.expectEqualStrings("", tokens2[1]);
}

test "utils: tokenizeCommandLine empty input yields no tokens" {
    const allocator = std.testing.allocator;
    const tokens = try tokenizeCommandLine(allocator, "");
    try std.testing.expectEqual(@as(usize, 0), tokens.len);
    allocator.free(tokens);
}

test "utils: runToolTimed enforces the timeout and kills the child process" {
    if (comptime builtin.os.tag != .windows) {
        const allocator = std.testing.allocator;
        var out: [64]u8 = undefined;
        try std.testing.expectError(error.RunTimeout, runToolTimed("sleep", &.{"5"}, &out, 50, allocator));
    }
}
