const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");
const log = @import("utils").log;

pub const List = @import("list.zig").List;
pub const ListItem = @import("list.zig").ListItem;
pub const ListItemAction = @import("list.zig").ListItemAction;
pub const Keyboard = @import("keyboard.zig").Keyboard;
pub const BottomBar = @import("bottombar.zig").BottomBar;
pub const Window = @import("window.zig").Window;
pub const theme = @import("theme_handler.zig");
pub const SearchBar = @import("search_bar.zig").SearchBar;

const QApp = qt.QApplication;

pub fn showError(msg: []const u8) void {
    log.info("{s}", .{msg});
}

pub fn renderList(
    self: *Window,
    allocator: std.mem.Allocator,
    items: []const ListItem,
    vis: config.VisualConfig,
    show_bottom_bar: bool,
    no_icons: bool,
    app: QApp,
) void {
    self.init(allocator, items, vis, !show_bottom_bar, no_icons, app);
}
