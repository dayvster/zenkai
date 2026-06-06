const std = @import("std");
const log = @import("utils").log;

pub const Config = struct {
    icon_size: i32,
    start_timer: bool,
    benchmark_all: bool,
    no_bottom_bar: bool,
    no_icons: bool,
    theme: ?[]const u8,
};

pub fn parse(args: [][:0]u8) Config {
    var cfg: Config = .{
        .icon_size = 32,
        .start_timer = false,
        .benchmark_all = false,
        .no_bottom_bar = false,
        .no_icons = false,
        .theme = null,
    };

    for (args) |arg_slice| {
        const arg: []const u8 = arg_slice;
        if (std.mem.startsWith(u8, arg, "--size=")) {
            cfg.icon_size = std.fmt.parseInt(i32, arg["--size=".len..], 10) catch 32;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            log.verbose = true;
        } else if (std.mem.eql(u8, arg, "--debug")) {
            cfg.start_timer = true;
            log.verbose = true;
        } else if (std.mem.startsWith(u8, arg, "--theme=")) {
            const val = arg["--theme=".len..];
            cfg.theme = if (val.len > 0) val else null;
        } else if (std.mem.eql(u8, arg, "--benchmark-all")) {
            cfg.benchmark_all = true;
            log.verbose = true;
        } else if (std.mem.eql(u8, arg, "--no-icons")) {
            cfg.no_icons = true;
        } else if (std.mem.eql(u8, arg, "--no-bottom-bar")) {
            cfg.no_bottom_bar = true;
        }
    }

    return cfg;
}
