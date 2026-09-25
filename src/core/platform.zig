const builtin = @import("builtin");

pub const AppReader = switch (builtin.os.tag) {
    .macos => @import("osx/appreader.zig").AppReader,
    .windows => @import("windows/appreader.zig").AppReader,
    .linux => @import("appreader.zig").AppReader,
    else => @compileError("Unsupported platform"),
};
