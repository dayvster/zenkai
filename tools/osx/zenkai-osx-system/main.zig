const std = @import("std");
const util = @import("osx_toolutil");

const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: c_ulong,
    f_bfree: c_ulong,
    f_bavail: c_ulong,
    f_files: c_ulong,
    f_ffree: c_ulong,
    f_favail: c_ulong,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
};

extern fn sysctlbyname(name: [*:0]const u8, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*const anyopaque, newlen: usize) c_int;
extern fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;

fn capture(allocator: std.mem.Allocator, parts: []const []const u8) []const u8 {
    const out = allocator.alloc(u8, util.MaxCapture) catch return "";

    const result = util.execCaptureRaw(allocator, parts, out) orelse {
        allocator.free(out);
        return "";
    };
    if (result.code != 0) {
        allocator.free(out);
        return "";
    }
    const owned = allocator.dupe(u8, out[0..result.len]) catch "";
    allocator.free(out);
    return owned;
}

fn battery(allocator: std.mem.Allocator) []const u8 {
    const raw = capture(allocator, &.{ "/usr/bin/pmset", "-g", "batt" });
    defer allocator.free(@constCast(raw));

    var percent: []const u8 = "?";
    if (std.mem.indexOfScalar(u8, raw, '%')) |idx| {
        var start = idx;
        while (start > 0 and raw[start - 1] >= '0' and raw[start - 1] <= '9') start -= 1;
        percent = raw[start..idx];
    }

    const state: []const u8 =
        if (std.mem.indexOf(u8, raw, "discharging") != null)
        "discharging"
    else if (std.mem.indexOf(u8, raw, "charged") != null)
        "full"
    else
        "charging";

    return std.fmt.allocPrint(allocator, "battery\t{s}\t{s}\n", .{ percent, state }) catch "";
}

fn memory(allocator: std.mem.Allocator) []const u8 {
    var total_bytes: u64 = 0;
    var total_len: usize = @sizeOf(u64);
    if (sysctlbyname("hw.memsize", @ptrCast(&total_bytes), &total_len, null, 0) != 0 or total_bytes == 0) {
        return allocator.dupe(u8, "memory\t?\n") catch "";
    }

    var pagesize: u64 = 4096;
    var ps_len: usize = 8;
    _ = sysctlbyname("hw.pagesize", @ptrCast(&pagesize), &ps_len, null, 0);

    const raw = capture(allocator, &.{ "/usr/bin/vm_stat" });
    defer allocator.free(@constCast(raw));

    var pages: u64 = 0;
    const count = countPages(raw, "Pages free:", &pages) +
        countPages(raw, "Pages active:", &pages) +
        countPages(raw, "Pages inactive:", &pages) +
        countPages(raw, "Pages occupied by compressor:", &pages) +
        countPages(raw, "Pages speculative:", &pages) +
        countPages(raw, "Pages wired down:", &pages);

    const used_bytes = total_bytes - (pages *% pagesize);
    const used_mb = used_bytes / (1024 * 1024);
    const total_gb = total_bytes / (1024 * 1024 * 1024);
    return std.fmt.allocPrint(allocator, "memory\t{d} MB used of {d} GB (pages: {d})\n", .{ used_mb, total_gb, count }) catch "";
}

fn countPages(buf: []const u8, label: []const u8, pages: *u64) u64 {
    const idx = std.mem.indexOf(u8, buf, label) orelse return 0;
    var i = idx + label.len;
    while (i < buf.len and (buf[i] == ' ' or buf[i] == ':')) i += 1;
    const start = i;
    while (i < buf.len and (buf[i] >= '0' and buf[i] <= '9')) i += 1;
    if (i == start) return 0;
    const value = std.fmt.parseInt(u64, buf[start..i], 10) catch return 0;
    pages.* += value;
    return value;
}

fn disk(allocator: std.mem.Allocator) []const u8 {
    var sv: Statvfs = undefined;
    if (statvfs("/", &sv) != 0) {
        return allocator.dupe(u8, "disk\t?\n") catch "";
    }
    const free_bytes = sv.f_bavail * sv.f_frsize;
    const free_gb = free_bytes / (1024 * 1024 * 1024);
    const total_gb = (sv.f_blocks * sv.f_frsize) / (1024 * 1024 * 1024);
    return std.fmt.allocPrint(allocator, "disk\t{d} GB free of {d} GB\n", .{ free_gb, total_gb }) catch "";
}

fn uptime(allocator: std.mem.Allocator) []const u8 {
    const raw = capture(allocator, &.{ "/usr/bin/sysctl", "-n", "kern.boottime" });
    defer allocator.free(@constCast(raw));

    const sec_idx = std.mem.indexOf(u8, raw, "sec = ") orelse {
        return allocator.dupe(u8, "uptime\t?\n") catch "";
    };
    var i = sec_idx + "sec = ".len;
    const start = i;
    while (i < raw.len and raw[i] >= '0' and raw[i] <= '9') i += 1;
    if (i == start) {
        return allocator.dupe(u8, "uptime\t?\n") catch "";
    }
    const boot_secs = std.fmt.parseInt(u64, raw[start..i], 10) catch return allocator.dupe(u8, "uptime\t?\n") catch "";

    const now = std.time.timestamp();
    const uptime_secs: u64 = @intCast(now - @as(i64, @intCast(boot_secs)));

    const days = uptime_secs / (24 * 3600);
    const hours = (uptime_secs / 3600) % 24;
    const mins = (uptime_secs / 60) % 60;

    return std.fmt.allocPrint(allocator, "uptime\t{d}d {d}h {d}m\n", .{ days, hours, mins }) catch "";
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next() orelse util.errExit("usage: zenkai-osx-system status", .{});
    const cmd = args_iter.next() orelse util.errExit("usage: zenkai-osx-system status", .{});
    if (!std.mem.eql(u8, cmd, "status")) util.errExit("unknown system command: {s}", .{cmd});

    const battery_line = battery(allocator);
    defer if (battery_line.len > 0) allocator.free(battery_line);
    const memory_line = memory(allocator);
    defer if (memory_line.len > 0) allocator.free(memory_line);
    const disk_line = disk(allocator);
    defer if (disk_line.len > 0) allocator.free(disk_line);
    const uptime_line = uptime(allocator);
    defer if (uptime_line.len > 0) allocator.free(uptime_line);

    _ = std.c.write(1, battery_line.ptr, battery_line.len);
    _ = std.c.write(1, memory_line.ptr, memory_line.len);
    _ = std.c.write(1, disk_line.ptr, disk_line.len);
    _ = std.c.write(1, uptime_line.ptr, uptime_line.len);
}