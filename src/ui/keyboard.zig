const std = @import("std");
const qt = @import("libqt6zig");
const List = @import("list.zig").List;
const utils = @import("utils");

const QShortcut = qt.QShortcut;
const QKeySequence = qt.QKeySequence;
const QWidget = qt.QWidget;
const QApp = qt.QApplication;
const QLineEdit = qt.QLineEdit;
const QKeyEvent = qt.QKeyEvent;

var L: *List = undefined;
var search_widget: QLineEdit = undefined;

fn currentRow() ?i32 {
    var idx = L.view.currentIndex();
    defer idx.delete();
    if (!idx.isValid()) return null;
    return idx.row();
}

fn focusSearch() void {
    var invalid = List.invalidIndex();
    defer invalid.delete();
    L.view.setCurrentIndex(invalid);
    search_widget.setFocus();
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
    const seq = QKeySequence.new2(key);
    defer seq.delete();
    const s = QShortcut.new2(seq, window);
    s.onActivated(handler);
}

fn scrollToTop() void {
    if (L.indices.items.len > 0) L.selectRow(0);
}

fn scrollToEnd() void {
    if (L.indices.items.len > 0) L.selectRow(@intCast(L.indices.items.len - 1));
}

fn onSearchKeyPress(edit: QLineEdit, event: QKeyEvent) callconv(.c) void {
    switch (event.key()) {
        qt.qnamespace_enums.Key.Key_Home => scrollToTop(),
        qt.qnamespace_enums.Key.Key_End => scrollToEnd(),
        else => edit.superKeyPressEvent(event),
    }
}

fn onEscape(_: QShortcut) callconv(.c) void {
    QApp.quit();
}

fn onPageUp(_: QShortcut) callconv(.c) void {
    const row = currentRow() orelse {
        if (L.indices.items.len > 0) L.selectRow(@intCast(L.indices.items.len - 1));
        return;
    };
    const target = @max(row - 10, 0);
    L.selectRow(target);
}

fn onPageDown(_: QShortcut) callconv(.c) void {
    const row = currentRow() orelse {
        if (L.indices.items.len > 0) L.selectRow(0);
        return;
    };
    const max_row = @as(i32, @intCast(@max(L.indices.items.len, 1) - 1));
    const target = @min(row + 10, max_row);
    L.selectRow(target);
}

fn onTab(_: QShortcut) callconv(.c) void {
    if (L.indices.items.len > 0) {
        if (currentRow() == null) L.selectRow(0);
    }
    L.view.setFocus();
}

fn onShiftTab(_: QShortcut) callconv(.c) void {
    focusSearch();
}

fn makeActionHandler(comptime n: usize) *const fn (QShortcut) callconv(.c) void {
    const H = struct {
        fn handler(_: QShortcut) callconv(.c) void {
            const actions = List.currentItemActions();
            if (n < actions.len) {
                utils.execute(actions[n].exec, L.allocator) catch {};
                QApp.quit();
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
        bind(window, "Enter", onEnter);
        bind(window, "Up", onUp);
        bind(window, "Down", onDown);
        bind(window, "Escape", onEscape);
        bind(window, "PgUp", onPageUp);
        bind(window, "PgDown", onPageDown);
        search.onKeyPressEvent(onSearchKeyPress);
        bind(window, "Tab", onTab);
        bind(window, "Shift+Tab", onShiftTab);
        inline for (0..10) |i| {
            var key_buf: [6]u8 = .{ 'C', 't', 'r', 'l', '+', if (i < 9) '1' + @as(u8, @intCast(i)) else '0' };
            bind(window, &key_buf, makeActionHandler(i));
        }
    }
};
