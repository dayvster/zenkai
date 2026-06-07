const builtin = @import("builtin");

pub const AppReader = switch (builtin.os.tag) {
    .macos => @import("osx/appreader.zig").AppReader,
    .windows => @compileError("Windows support not implemented"),
    else => @import("appreader.zig").AppReader,
};
