const std = @import("std");
const qt = @import("libqt6zig");

const List = @import("list.zig").List;
const ListItem = @import("list.zig").ListItem;
const Keyboard = @import("keyboard.zig").Keyboard;
const BottomBar = @import("bottombar.zig").BottomBar;

const QApp = qt.QApplication;
const QWidget = qt.QWidget;
const QVBoxLayout = qt.QVBoxLayout;
const QLineEdit = qt.QLineEdit;
const QCloseEvent = qt.QCloseEvent;

var g_window: *Window = undefined;

fn onSearchTextChanged(_: QLineEdit, text_cstr: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(text_cstr);
    g_window.list.setFilter(text);
}

fn onWindowClose(_: QWidget, _: QCloseEvent) callconv(.c) void {
    QApp.Quit();
}

pub const Window = struct {
    allocator: std.mem.Allocator,
    widget: QWidget,
    search_bar: QLineEdit,
    list: List,
    bottom_bar: ?BottomBar,

    pub fn init(
        self: *Window,
        allocator: std.mem.Allocator,
        items: []const ListItem,
        icon_size: i32,
        no_bottom_bar: bool,
        no_icons: bool,
    ) void {
        List.setNoIcons(no_icons);

        const win_w: i32 = 600;
        const win_h: i32 = 500;

        var window = QWidget.New2();
        window.SetWindowTitle("zenkai");

        const wt = qt.qnamespace_enums.WindowType;
        window.SetWindowFlags(
            wt.Tool |
                wt.FramelessWindowHint |
                wt.WindowStaysOnTopHint |
                wt.NoDropShadowWindowHint,
        );

        const main_layout = QVBoxLayout.New(window);

        var search_bar = QLineEdit.New2();
        search_bar.SetPlaceholderText("Search apps...");
        search_bar.SetClearButtonEnabled(false);

        var list = List.fromItems(allocator, items, icon_size);
        list.setFilter("");

        main_layout.AddWidget(search_bar);
        main_layout.AddWidget(list.view);

        self.* = .{
            .allocator = allocator,
            .widget = window,
            .search_bar = search_bar,
            .list = list,
            .bottom_bar = null,
        };

        if (!no_bottom_bar) {
            var bar = BottomBar.init(allocator, window);
            bar.setup(&self.list);
            bar.setDefaultActions();
            main_layout.AddWidget(bar.container);
            self.bottom_bar = bar;
        }

        window.SetMinimumSize2(win_w, win_h);
        window.SetMaximumSize2(win_w, win_h);

        const screen = window.Screen();
        const screen_rect = screen.Geometry();
        window.SetGeometry(
            @divTrunc(screen_rect.Width() - win_w, 2),
            @divTrunc(screen_rect.Height() - win_h, 2),
            win_w,
            win_h,
        );

        g_window = self;

        window.OnCloseEvent(onWindowClose);
        search_bar.OnTextChanged(onSearchTextChanged);
        Keyboard.setup(window, &self.list);
    }

    pub fn show(self: *Window) void {
        self.widget.Show();
    }

    pub fn exec() void {
        _ = QApp.Exec();
    }

    pub fn deinit(self: *Window) void {
        self.list.deinit();
        if (self.bottom_bar) |*bar| bar.deinit();
        self.search_bar.Delete();
        self.widget.Delete();
    }
};
