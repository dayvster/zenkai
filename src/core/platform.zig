const builtin = @import("builtin");

pub const AppReader = switch (builtin.os.tag) {
    .macos => @import("osx/appreader.zig").AppReader,
    .windows => @compileError("Windows support not implemented"),
    .linux => @import("appreader.zig").AppReader,
    else => @compileError("Unsupported platform"),
};
