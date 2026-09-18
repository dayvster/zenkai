const std = @import("std");

pub const MaxCapture = 64 * 1024;

pub extern "c" var environ: [*:null]?[*:0]u8;

pub const OsError = error{CaptureFailed, SpawnFailed};

pub fn print(comptime fmt: []const u8, args: anytype) void {
    const buf = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch return;
    defer std.heap.page_allocator.free(buf);
    _ = std.c.write(1, buf.ptr, buf.len);
}

pub fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("osx tool error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

pub fn usageExit() noreturn {
    std.process.exit(2);
}

pub fn buildArgv(allocator: std.mem.Allocator, parts: []const []const u8) ![:null]?[*:0]u8 {
    const argv = try allocator.allocSentinel(?[*:0]u8, parts.len, null);
    var count: usize = 0;
    errdefer {
        for (argv[0..count]) |ptr| if (ptr) |arg| allocator.free(arg);
        allocator.free(argv);
    }
    for (parts, 0..) |part, i| {
        const z = try allocator.dupeZ(u8, part);
        argv[i] = z.ptr;
        count += 1;
    }
    return argv;
}

fn freeArgv(allocator: std.mem.Allocator, argv: [:null]?[*:0]u8) void {
    for (argv) |ptr| if (ptr) |arg| {
        allocator.free(arg);
    };
    allocator.free(argv);
}

pub const CaptureResult = struct {
    len: usize,
    code: c_int,
};

pub fn execCaptureRaw(allocator: std.mem.Allocator, parts: []const []const u8, out: []u8) ?CaptureResult {
    const argv = buildArgv(allocator, parts) catch return null;
    defer freeArgv(allocator, argv);

    var pipefd: [2]c_int = undefined;
    if (std.c.pipe(&pipefd) != 0) return null;

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipefd[0]);
        _ = std.c.close(pipefd[1]);
        return null;
    }

    if (pid == 0) {
        _ = std.c.close(pipefd[0]);
        _ = std.c.dup2(pipefd[1], 1);
        _ = std.c.dup2(pipefd[1], 2);
        if (pipefd[1] != 1) _ = std.c.close(pipefd[1]);
        _ = std.c.execve(argv[0].?, argv.ptr, environ);
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
    if (std.c.waitpid(pid, &status, 0) < 0) return null;

    const code = if (std.c.W.IFEXITED(status)) std.c.W.EXITSTATUS(status) else -1;
    return .{ .len = total, .code = code };
}

pub fn execCapture(allocator: std.mem.Allocator, parts: []const []const u8, out: []u8) !usize {
    const result = execCaptureRaw(allocator, parts, out) orelse return error.CaptureFailed;
    if (result.code != 0) return error.CaptureFailed;
    return result.len;
}

pub fn execWait(allocator: std.mem.Allocator, parts: []const []const u8) !u8 {
    const argv = try buildArgv(allocator, parts);
    defer freeArgv(allocator, argv);

    const pid = std.c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        _ = std.c.execve(argv[0].?, argv.ptr, environ);
        std.c._exit(127);
    }

    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) < 0) return error.SpawnFailed;
    if (!std.c.W.IFEXITED(status)) return error.SpawnFailed;
    return @intCast(std.c.W.EXITSTATUS(status));
}

pub fn sanitize(buf: []u8) void {
    for (buf) |*b| {
        if (b.* == '\t' or b.* == '\n' or b.* == '\r') b.* = ' ';
    }
}

pub fn getenvHome() ?[]const u8 {
    if (std.c.getenv("HOME")) |home_raw| {
        return std.mem.sliceTo(home_raw, 0);
    }
    return null;
}

pub fn appleQuote(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\"");
    for (s) |c| {
        if (c == '"' or c == '\\') try out.append('\\');
        try out.append(c);
    }
    try out.appendSlice(allocator, "\"");
    return try out.toOwnedSlice(allocator);
}

pub fn appendField(out: *std.ArrayList(u8), field: []const u8) !void {
    for (field) |c| {
        if (c == '\t' or c == '\n' or c == '\r') {
            try out.append(' ');
        } else {
            try out.append(c);
        }
    }
}