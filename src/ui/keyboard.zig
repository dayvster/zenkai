const qt = @import("libqt6zig");
const List = @import("list.zig").List;

const QShortcut = qt.QShortcut;
const QKeySequence = qt.QKeySequence;
const QWidget = qt.QWidget;
const QApp = qt.QApplication;

var L: *List = undefined;

fn currentRow() ?i32 {
    var idx = L.view.CurrentIndex();
    defer idx.Delete();
    if (!idx.IsValid()) return null;
    return idx.Row();
}

fn onEnter(_: QShortcut) callconv(.c) void {
    L.launchSelected();
}

fn onUp(_: QShortcut) callconv(.c) void {
    const row = currentRow() orelse return;
    if (row > 0) L.selectRow(row - 1);
}

fn onDown(_: QShortcut) callconv(.c) void {
    const row = currentRow() orelse return;
    if (row < L.indices.items.len - 1) L.selectRow(row + 1);
}

fn bind(window: QWidget, key: []const u8, handler: *const fn (QShortcut) callconv(.c) void) void {
    const seq = QKeySequence.New2(key);
    defer seq.Delete();
    const s = QShortcut.New2(seq, window);
    s.OnActivated(handler);
}

fn onEscape(_: QShortcut) callconv(.c) void {
    QApp.Quit();
}

pub const Keyboard = struct {
    pub fn setup(window: QWidget, list: *List) void {
        L = list;
        bind(window, "Return", onEnter);
        bind(window, "Up", onUp);
        bind(window, "Down", onDown);
        bind(window, "Escape", onEscape);
    }
};
