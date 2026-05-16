const std = @import("std");
const qt = @import("libqt6zig");
const List = @import("list.zig").List;
const utils = @import("../utils/utils.zig");

const QShortcut = qt.QShortcut;
const QKeySequence = qt.QKeySequence;
const QWidget = qt.QWidget;
const QApp = qt.QApplication;

var L: *List = undefined;

fn firstVisible() i32 {
    const count = L.widget.Count();
    var row: i32 = 0;
    while (row < count) : (row += 1) {
        if (!L.widget.Item(row).IsHidden()) return row;
    }
    return -1;
}

fn nextVisible(from: i32) i32 {
    const count = L.widget.Count();
    var row = from + 1;
    while (row < count) : (row += 1) {
        if (!L.widget.Item(row).IsHidden()) return row;
    }
    return -1;
}

fn prevVisible(from: i32) i32 {
    var row = from - 1;
    while (row >= 0) : (row -= 1) {
        if (!L.widget.Item(row).IsHidden()) return row;
    }
    return -1;
}

fn onEnter(_: QShortcut) callconv(.c) void {
    const row = L.widget.CurrentRow();
    if (row < 0) {
        const first = firstVisible();
        if (first >= 0) L.widget.SetCurrentRow(first);
        return;
    }
    const idx = @as(usize, @intCast(row));
    if (idx >= L.exec_cmds.items.len) return;
    if (L.widget.Item(row).IsHidden()) return;
    utils.execute(L.exec_cmds.items[idx]) catch {};
    QApp.Quit();
}

fn onUp(_: QShortcut) callconv(.c) void {
    const row = L.widget.CurrentRow();
    const prev = if (row > 0) prevVisible(row) else -1;
    if (prev >= 0) L.widget.SetCurrentRow(prev);
}

fn onDown(_: QShortcut) callconv(.c) void {
    const row = L.widget.CurrentRow();
    const next = if (row >= 0) nextVisible(row) else firstVisible();
    if (next >= 0) L.widget.SetCurrentRow(next);
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
