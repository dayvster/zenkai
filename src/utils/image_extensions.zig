const std = @import("std");

pub const all = [_][]const u8{
    ".png",
    ".jpg",
    ".jpeg",
    ".gif",
    ".bmp",
    ".webp",
};

pub const ImageExtension = blk: {
    var field_names: [all.len][:0]const u8 = undefined;
    var field_values: [all.len]u8 = undefined;
    for (all, 0..) |extension, index| {
        field_names[index] = std.fmt.comptimePrint("{s}", .{extension[1..]});
        field_values[index] = @intCast(index);
    }
    break :blk @Enum(u8, .exhaustive, &field_names, &field_values);
};

pub fn toString(extension: ImageExtension) []const u8 {
    return all[@intCast(@backingInt(extension))];
}

test "image extension enum values map to suffixes" {
    inline for (all, 0..) |extension, index| {
        const tag: ImageExtension = @fromBackingInt(@as(u8, @intCast(index)));
        try std.testing.expectEqualStrings(extension[1..], @tagName(tag));
        try std.testing.expectEqualStrings(extension, toString(tag));
    }
}
