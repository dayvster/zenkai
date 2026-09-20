const std = @import("std");
const util = @import("osx_toolutil");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next() orelse util.errExit("usage: zenkai-osx-audio <status|up|down|set N|mute|unmute>", .{});
    const cmd = args_iter.next() orelse util.errExit("usage: zenkai-osx-audio <status|up|down|set N|mute|unmute>", .{});

    if (std.mem.eql(u8, cmd, "status")) {
        const out = try allocator.alloc(u8, util.MaxCapture);
        defer allocator.free(out);
        const n = util.execCapture(allocator, &.{
            "/usr/bin/osascript",
            "-e", "return output volume of (get volume settings)",
            "-e", "return output muted of (get volume settings)",
        }, out) catch util.errExit("audio status failed", .{});

        var it = std.mem.splitScalar(u8, out[0..n], '\n');
        const vol_line = std.mem.trim(u8, it.next() orelse "", " \r");
        const mute_line = std.mem.trim(u8, it.next() orelse "", " \r");
        util.print("VOLUME\t{s}\t{s}\n", .{ vol_line, mute_line });
        return;
    }

    var script_buf: [64]u8 = undefined;
    const side_effect: []const u8 =
        if (std.mem.eql(u8, cmd, "up"))
        "set volume output volume ((output volume of (get volume settings)) + 10)"
    else if (std.mem.eql(u8, cmd, "down"))
        "set volume output volume ((output volume of (get volume settings)) - 10)"
    else if (std.mem.eql(u8, cmd, "mute") or std.mem.eql(u8, cmd, "off"))
        "set volume output muted true"
    else if (std.mem.eql(u8, cmd, "unmute") or std.mem.eql(u8, cmd, "on"))
        "set volume output muted false"
    else if (std.mem.eql(u8, cmd, "set")) blk: {
        const raw = args_iter.next() orelse util.errExit("audio set requires a level", .{});
        const level = std.fmt.parseInt(u8, raw, 10) catch util.errExit("invalid volume level: {s}", .{raw});
        break :blk std.fmt.bufPrint(&script_buf, "set volume output volume {d}", .{level}) catch util.errExit("volume out of range", .{});
    } else util.errExit("unknown audio command: {s}", .{cmd});

    const code = util.execWait(allocator, &.{ "/usr/bin/osascript", "-e", side_effect }) catch util.errExit("audio command failed", .{});
    if (code != 0) util.errExit("audio command exited with status {d}", .{code});
}