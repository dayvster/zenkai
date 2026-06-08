const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");

pub const List = @import("list.zig").List;
pub const ListItem = @import("list.zig").ListItem;
pub const ListItemAction = @import("list.zig").ListItemAction;
pub const Keyboard = @import("keyboard.zig").Keyboard;
pub const BottomBar = @import("bottombar.zig").BottomBar;
pub const Window = @import("window.zig").Window;
pub const theme = @import("theme_handler.zig");

const QApp = qt.QApplication;

pub fn showError(msg: []const u8) void {
    const QLabel = qt.QLabel;
    var label = QLabel.New3(msg);
    defer label.Delete();
    label.SetAlignment(@as(i32, 0x8004));
    label.SetWindowFlag(2048);
    label.SetWindowFlag(262144);
    label.SetFixedSize2(300, 80);
    const screen = label.Screen();
    const screen_rect = screen.Geometry();
    label.Move(
        @divTrunc(screen_rect.Width() - 300, 2),
        @divTrunc(screen_rect.Height() - 80, 2),
    );
    label.Show();
    _ = QApp.Exec();
}

pub fn renderList(
    self: *Window,
    allocator: std.mem.Allocator,
    items: []const ListItem,
    vis: config.VisualConfig,
    show_bottom_bar: bool,
    no_icons: bool,
) void {
    self.init(allocator, items, vis, !show_bottom_bar, no_icons);
}
