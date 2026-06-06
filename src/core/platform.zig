const builtin = @import("builtin");
const linux = @import("appreader.zig");

pub fn runForLinux() !void {}
pub fn runForOSX() !void {}
pub fn funForWindows() !void {}

pub const platform = switch (builtin.os.tag) {
    .linux => @compileError("Not implemented yet"),
    .macos => @compileError("not implemented yet"),
    .windows => @compileError("Not implemented yet"),
};
