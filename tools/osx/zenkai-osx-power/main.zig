const std = @import("std");
const util = @import("osx_toolutil");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next() orelse util.errExit("usage: zenkai-osx-power <lock|sleep|displaysleep|restart|shutdown|logout>", .{});
    const cmd = args_iter.next() orelse util.errExit("usage: zenkai-osx-power <lock|sleep|displaysleep|restart|shutdown|logout>", .{});

    const parts: []const []const u8 =
        if (std.mem.eql(u8, cmd, "lock"))
        &.{ "/System/Library/CoreServices/Menu Extras/User.menu/Contents/Resources/CGSession", "-suspend" }
    else if (std.mem.eql(u8, cmd, "sleep"))
        &.{ "/usr/bin/pmset", "sleepnow" }
    else if (std.mem.eql(u8, cmd, "displaysleep") or std.mem.eql(u8, cmd, "display-sleep"))
        &.{ "/usr/bin/pmset", "displaysleepnow" }
    else if (std.mem.eql(u8, cmd, "restart"))
        &.{ "/usr/bin/osascript", "-e", "tell application \"System Events\" to restart" }
    else if (std.mem.eql(u8, cmd, "shutdown"))
        &.{ "/usr/bin/osascript", "-e", "tell application \"System Events\" to shut down" }
    else if (std.mem.eql(u8, cmd, "logout") or std.mem.eql(u8, cmd, "log-out"))
        &.{ "/usr/bin/osascript", "-e", "tell application \"System Events\" to log out" }
    else util.errExit("unknown power command: {s}", .{cmd});

    const code = util.execWait(allocator, parts) catch util.errExit("failed to run power command", .{});
    if (code != 0) util.errExit("power command exited with status {d}", .{code});
}