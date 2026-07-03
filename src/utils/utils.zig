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
