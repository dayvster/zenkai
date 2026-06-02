const std = @import("std");
const qt = @import("libqt6zig");
const List = @import("list.zig").List;
const DesktopApp = @import("desktopapp").DesktopApp;
const utils = @import("utils");

const QShortcut = qt.QShortcut;
const QKeySequence = qt.QKeySequence;
const QWidget = qt.QWidget;
const QApp = qt.QApplication;
const QModelIndex = qt.QModelIndex;

var L: *List = undefined;

fn onEnter(_: QShortcut) callconv(.c) void {
    var idx = L.view.CurrentIndex();
    defer idx.Delete();

    if (!idx.IsValid()) {
        if (L.indices.items.len > 0) {
            var invalid = QModelIndex.New3();
            defer invalid.Delete();
            var first = L.model.Index(0, 0, invalid);
            defer first.Delete();
            L.view.SetCurrentIndex(first);
        }
        return;
    }
    const row = @as(usize, @intCast(idx.Row()));
    if (row >= L.indices.items.len) return;
    const app = &L.apps[L.indices.items[row]];
    const expanded = app.expandExec(L.allocator) catch return;
    defer L.allocator.free(expanded);
    utils.execute(expanded, L.allocator) catch {};
    QApp.Quit();
}

fn onUp(_: QShortcut) callconv(.c) void {
    var idx = L.view.CurrentIndex();
    defer idx.Delete();

    if (!idx.IsValid()) return;
    const row = idx.Row();
    if (row > 0) {
        var invalid = QModelIndex.New3();
        defer invalid.Delete();
        var target = L.model.Index(row - 1, 0, invalid);
        defer target.Delete();
        L.view.SetCurrentIndex(target);
    }
}

fn onDown(_: QShortcut) callconv(.c) void {
    var idx = L.view.CurrentIndex();
    defer idx.Delete();

    if (!idx.IsValid()) return;
    const row = idx.Row();
    const count = @as(i32, @intCast(L.indices.items.len));
    if (row < count - 1) {
        var invalid = QModelIndex.New3();
        defer invalid.Delete();
        var target = L.model.Index(row + 1, 0, invalid);
        defer target.Delete();
        L.view.SetCurrentIndex(target);
    }
}

fn bind(window: QWidget, key: []const u8, handler: *const fn (QShortcut) callconv(.c) void) void {
    const seq = QKeySequence.New2(key);
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
