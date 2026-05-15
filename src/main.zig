const std = @import("std");
const appreader = @import("core/appreader.zig");
const qt = @import("libqt6zig");
const ui = @import("ui/ui.zig");

const QApp = qt.QApplication;
const QLabel = qt.QLabel;
const QWidget = qt.QWidget;
const QVBoxLayout = qt.QVBoxLayout;
const QLineEdit = qt.QLineEdit;
const QCloseEvent = qt.QCloseEvent;
const QShortcut = qt.QShortcut;
const QKeySequence = qt.QKeySequence;
const main_qss = @embedFile("styles/main.qss");
const dark_qss = @embedFile("styles/dark.theme.qss");

const stylesheet = blk: {
    var buf: [main_qss.len + dark_qss.len:0]u8 = undefined;
    @memcpy(buf[0..main_qss.len], main_qss);
    @memcpy(buf[main_qss.len..], dark_qss);
    break :blk buf;
};
var search_list: *ui.List = undefined;

fn onSearchTextChanged(_: QLineEdit, text_cstr: [*:0]const u8) callconv(.c) void {
    const text = std.mem.span(text_cstr);
    search_list.setFilter(text);
}

fn onWindowClose(_: QWidget, _: QCloseEvent) callconv(.c) void {
    QApp.Quit();
}

fn onEscapePressed(_: QShortcut) callconv(.c) void {
    QApp.Quit();
}

pub fn main(init: std.process.Init) !void {
    const argv = try qt.init(init.gpa, init.minimal.args);
    defer qt.deinit(init.gpa, argv);

    var argc: i32 = @intCast(argv.len);
    const app = QApp.New(std.heap.page_allocator, &argc, argv);
    app.SetStyleSheet(&stylesheet);
    defer app.Delete();

    var reader = appreader.AppReader.init(init.gpa);
    errdefer reader.deinit();

    reader.load() catch {
        var error_label = QLabel.New3("Error loading desktop files");
        error_label.SetAlignment(@as(i32, 0x8004));
        error_label.SetWindowFlag(2048);
        error_label.SetWindowFlag(262144);
        error_label.SetFixedSize2(300, 80);
        const screen = error_label.Screen();
        const screen_rect = screen.Geometry();
        const x = @divTrunc(screen_rect.Width() - 300, 2);
        const y = @divTrunc(screen_rect.Height() - 80, 2);
        error_label.Move(x, y);
        error_label.Show();
        return;
    };
    defer reader.deinit();

    var list = ui.List.init(init.gpa, reader.apps.items);
    defer list.deinit();

    const win_w: i32 = 600;
    const win_h: i32 = 500;

    var window = QWidget.New2();
    window.SetWindowTitle("zlauncher");

    const wt = qt.qnamespace_enums.WindowType;
    window.SetWindowFlags(
        wt.Tool |
            wt.FramelessWindowHint |
            wt.WindowStaysOnTopHint |
            wt.NoDropShadowWindowHint |
            wt.MSWindowsFixedSizeDialogHint,
    );

    const main_layout = QVBoxLayout.New(window);

    var search_bar = QLineEdit.New2();
    search_bar.SetPlaceholderText("Search apps...");
    search_bar.SetClearButtonEnabled(true);
    main_layout.AddWidget(search_bar);

    main_layout.AddWidget(list.widget);

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

    window.OnCloseEvent(onWindowClose);

    const escape_seq = QKeySequence.New2("Escape");
    const escape_shortcut = QShortcut.New2(escape_seq, window);
    escape_shortcut.OnActivated(onEscapePressed);

    search_list = &list;
    search_bar.OnTextChanged(onSearchTextChanged);

    window.Show();

    _ = QApp.Exec();
}
