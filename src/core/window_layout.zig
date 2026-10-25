const std = @import("std");
pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    pub fn validate(self: Rect) !void {
        if (self.width <= 0 or self.height <= 0 or
            @as(i64, self.x) + self.width > std.math.maxInt(i32) or
            @as(i64, self.y) + self.height > std.math.maxInt(i32)) return error.InvalidGeometry;
    }
    pub fn intersection(self: Rect, other: Rect) i64 {
        const w = @max(0, @min(@as(i64, self.x) + self.width, @as(i64, other.x) + other.width) - @max(self.x, other.x));
        const h = @max(0, @min(@as(i64, self.y) + self.height, @as(i64, other.y) + other.height) - @max(self.y, other.y));
        return @as(i64, w) * h;
    }
};
pub const Action = enum {
    left,
    right,
    top,
    bottom,
    maximize,
    center,
    next_display,
    pub fn label(self: Action) []const u8 {
        return switch (self) {
            .left => "Left Half",
            .right => "Right Half",
            .top => "Top Half",
            .bottom => "Bottom Half",
            .maximize => "Maximize",
            .center => "Center Window",
            .next_display => "Move to Next Display",
        };
    }
};
pub fn destination(current: Rect, screens: []const Rect, action: Action) !Rect {
    if (screens.len == 0) return error.NoDisplay;
    try current.validate();
    for (screens) |screen| try screen.validate();
    var index: usize = 0;
    for (screens, 0..) |screen, i| if (current.intersection(screen) > current.intersection(screens[index])) {
        index = i;
    };
    if (action == .next_display) {
        if (screens.len < 2) return error.NoOtherDisplay;
        index = (index + 1) % screens.len;
    }
    const screen = screens[index];
    if (screen.width < 2 or screen.height < 2) return error.InvalidGeometry;
    var result = screen;
    switch (action) {
        .left => result.width = @divTrunc(screen.width, 2),
        .right => {
            const half = @divTrunc(screen.width, 2);
            result.x += half;
            result.width -= half;
        },
        .top => result.height = @divTrunc(screen.height, 2),
        .bottom => {
            const half = @divTrunc(screen.height, 2);
            result.y += half;
            result.height -= half;
        },
        .maximize => {},
        .center, .next_display => {
            result.width = @min(@max(current.width, 1), screen.width);
            result.height = @min(@max(current.height, 1), screen.height);
            result.x += @divTrunc(screen.width - result.width, 2);
            result.y += @divTrunc(screen.height - result.height, 2);
        },
    }
    return result;
}
test "window layouts respect work areas, negative origins and odd dimensions" {
    const screens = [_]Rect{ .{ .x = -1920, .y = 0, .width = 1920, .height = 1040 }, .{ .x = 0, .y = 24, .width = 1921, .height = 1055 } };
    const current = Rect{ .x = 100, .y = 100, .width = 800, .height = 600 };
    const left = try destination(current, &screens, .left);
    const right = try destination(current, &screens, .right);
    try std.testing.expectEqual(@as(i32, 1921), left.width + right.width);
    try std.testing.expectEqual(@as(i32, 24), right.y);
    const next = try destination(current, &screens, .next_display);
    try std.testing.expect(next.x < 0 and next.width == 800);
    try std.testing.expectError(error.NoOtherDisplay, destination(current, screens[0..1], .next_display));
}

test "invalid display bounds do not overflow layout arithmetic" {
    const current = Rect{ .x = 0, .y = 0, .width = 800, .height = 600 };
    const invalid = [_]Rect{.{ .x = std.math.maxInt(i32), .y = 0, .width = 100, .height = 100 }};
    try std.testing.expectError(error.InvalidGeometry, destination(current, &invalid, .right));
    try std.testing.expectError(error.NoDisplay, destination(current, &.{}, .left));
}
