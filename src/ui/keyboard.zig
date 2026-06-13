const std = @import("std");
const qt = @import("libqt6zig");
const List = @import("list.zig").List;
const utils = @import("utils");

const QShortcut = qt.QShortcut;
const QKeySequence = qt.QKeySequence;
const QWidget = qt.QWidget;
const QApp = qt.QApplication;
const QLineEdit = qt.QLineEdit;

var L: *List = undefined;
var search_widget: QLineEdit = undefined;

fn currentRow() ?i32 {
    var idx = L.view.CurrentIndex();
    defer idx.Delete();
    if (!idx.IsValid()) return null;
    return idx.Row();
}

fn focusSearch() void {
    var invalid = List.invalidIndex();
    defer invalid.Delete();
    L.view.SetCurrentIndex(invalid);
    search_widget.SetFocus();
}

fn onEnter(_: QShortcut) callconv(.c) void {
    L.launchSelected();
}

fn onUp(_: QShortcut) callconv(.c) void {
    const row = currentRow() orelse {
        if (L.indices.items.len > 0) L.selectRow(@intCast(L.indices.items.len - 1));
        return;
    };
    if (row > 0) {
        L.selectRow(row - 1);
    } else {
        focusSearch();
    }
}

fn onDown(_: QShortcut) callconv(.c) void {
    const row = currentRow() orelse {
        if (L.indices.items.len > 0) L.selectRow(0);
        return;
    };
    if (row < L.indices.items.len - 1) {
        L.selectRow(row + 1);
    } else {
        focusSearch();
    }
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

fn makeActionHandler(comptime n: usize) *const fn (QShortcut) callconv(.c) void {
    const H = struct {
        fn handler(_: QShortcut) callconv(.c) void {
            const actions = List.currentItemActions();
            if (n < actions.len) {
                utils.execute(actions[n].exec, L.allocator) catch {};
                QApp.Quit();
            }
        }
    };
    return H.handler;
}

pub const Keyboard = struct {
    pub fn setup(window: QWidget, list: *List, search: QLineEdit) void {
        L = list;
        search_widget = search;
        bind(window, "Return", onEnter);
        bind(window, "Up", onUp);
        bind(window, "Down", onDown);
        bind(window, "Escape", onEscape);
        inline for (0..10) |i| {
            var key_buf: [6]u8 = .{ 'C', 't', 'r', 'l', '+', if (i < 9) '1' + @as(u8, @intCast(i)) else '0' };
            bind(window, &key_buf, makeActionHandler(i));
        }
    }
};
