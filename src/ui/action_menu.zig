const std = @import("std");
const qt = @import("libqt6zig");
const List = @import("list.zig").List;
const icons = @import("icon_loader.zig");
const info = @import("info.zig");
const browser_actions = @import("browser_actions.zig");
const windows = @import("../core/window_switcher.zig");

const Operation = union(enum) { open, custom: usize, browser: browser_actions.Action, window: windows.layout.Action, copy_name, copy_command, information, refresh };
const Row = struct { action: qt.QAction, label: []const u8, operation: Operation };

// Windows has no freedesktop icon theme. Keep action affordances visible there
// with small line glyphs; a platform/theme icon still takes precedence.
fn actionIcon(menu: qt.QMenu, name: []const u8) qt.QIcon {
    const themed = icons.load(name);
    if (!themed.isNull() or name.len == 0) return themed;
    themed.delete();
    const pixmap = qt.QPixmap.new2(20, 20);
    defer pixmap.delete();
    const transparent = qt.QColor.new15(0, 0, 0, 0);
    defer transparent.delete();
    pixmap.fill1(transparent);
    const palette = menu.palette();
    const color = palette.color2(qt.qpalette_enums.ColorRole.WindowText);
    const painter = qt.QPainter.new();
    defer painter.delete();
    _ = painter.begin(pixmap);
    painter.setRenderHint(1);
    painter.setPen(color);
    if (std.mem.eql(u8, name, "edit-copy")) {
        painter.drawRoundedRect2(7, 7, 9, 10, 2, 2);
        painter.drawLine3(4, 13, 4, 3);
        painter.drawLine3(4, 3, 12, 3);
    } else if (std.mem.eql(u8, name, "dialog-information")) {
        painter.drawEllipse3(3, 3, 14, 14);
        painter.drawLine3(10, 9, 10, 14);
        painter.drawLine3(10, 6, 10, 7);
    } else if (std.mem.eql(u8, name, "view-refresh")) {
        painter.drawEllipse3(4, 4, 12, 12);
        painter.drawLine3(16, 3, 16, 8);
        painter.drawLine3(12, 8, 16, 8);
    } else if (std.mem.startsWith(u8, name, "folder")) {
        painter.drawRoundedRect2(3, 6, 14, 11, 2, 2);
        painter.drawLine3(4, 6, 4, 3);
        painter.drawLine3(4, 3, 9, 3);
        painter.drawLine3(9, 3, 11, 6);
    } else {
        painter.drawLine3(4, 16, 16, 4);
        painter.drawLine3(7, 4, 16, 4);
        painter.drawLine3(16, 4, 16, 13);
    }
    _ = painter.end();
    return qt.QIcon.new2(pixmap);
}

const State = struct {
    menu: qt.QMenu,
    search: qt.QLineEdit,
    empty: qt.QWidgetAction,
    rows: std.ArrayList(Row) = .empty,
    chosen: ?usize = null,
    anchor_x: i32 = 0,
    anchor_y: i32 = 0,

    fn add(self: *State, label: []const u8, icon_name: []const u8, operation: Operation) !void {
        const owned = try std.heap.page_allocator.dupe(u8, label);
        errdefer std.heap.page_allocator.free(owned);
        const icon = actionIcon(self.menu, icon_name);
        defer icon.delete();
        const action = self.menu.addAction3(icon, label);
        var hint: [512]u8 = undefined;
        const shortcut: ?[]const u8 = switch (operation) {
            .open => "Enter",
            .custom => |i| if (i < 10) std.fmt.bufPrint(&hint, "Ctrl+{d}", .{(i + 1) % 10}) catch null else null,
            else => null,
        };
        if (shortcut) |text| {
            const caption = try std.fmt.allocPrint(std.heap.page_allocator, "{s}\t{s}", .{ label, text });
            defer std.heap.page_allocator.free(caption);
            action.setText(caption);
        }
        try self.rows.append(std.heap.page_allocator, .{ .action = action, .label = owned, .operation = operation });
    }
};
var active: ?*State = null;
pub fn isOpen() bool {
    return active != null;
}

fn matches(label: []const u8, query: []const u8) bool {
    if (query.len > label.len) return false;
    for (0..label.len - query.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(label[i..][0..query.len], query)) return true;
    }
    return false;
}
fn filter(_: qt.QLineEdit, value: [*:0]const u8) callconv(.c) void {
    const state = active orelse return;
    var first = true;
    for (state.rows.items) |row| {
        const visible = matches(row.label, std.mem.span(value));
        row.action.setVisible(visible);
        if (visible and first) {
            state.menu.setActiveAction(row.action);
            first = false;
        }
    }
    state.empty.setVisible(first);
}
fn key(edit: qt.QLineEdit, event: qt.QKeyEvent) callconv(.c) void {
    const state = active orelse return;
    const keys = qt.qnamespace_enums.Key;
    if (event.modifiers() & qt.qnamespace_enums.KeyboardModifier.ControlModifier != 0) {
        if (event.key() == keys.Key_K) {
            _ = state.menu.close();
            return;
        }
        if (event.key() >= keys.Key_0 and event.key() <= keys.Key_9) {
            const number: usize = @intCast(event.key() - keys.Key_0);
            const target = if (number == 0) 9 else number - 1;
            for (state.rows.items, 0..) |row, i| {
                if (row.operation == .custom and row.operation.custom == target and row.action.isVisible()) {
                    state.chosen = i;
                    _ = state.menu.close();
                    return;
                }
            }
        }
    }
    switch (event.key()) {
        keys.Key_Escape => {
            _ = state.menu.close();
        },
        keys.Key_Return, keys.Key_Enter => {
            for (state.rows.items, 0..) |row, i| {
                if (row.action.isVisible() and row.action.ptr == state.menu.activeAction().ptr) {
                    state.chosen = i;
                    _ = state.menu.close();
                    break;
                }
            }
        },
        keys.Key_Up, keys.Key_Down => {
            const count = state.rows.items.len;
            if (count == 0) return;
            var index: usize = if (event.key() == keys.Key_Down) count - 1 else 0;
            for (state.rows.items, 0..) |row, i| {
                if (row.action.ptr == state.menu.activeAction().ptr) {
                    index = i;
                    break;
                }
            }
            for (0..count) |_| {
                index = if (event.key() == keys.Key_Down) (index + 1) % count else (index + count - 1) % count;
                if (state.rows.items[index].action.isVisible()) {
                    state.menu.setActiveAction(state.rows.items[index].action);
                    break;
                }
            }
        },
        else => edit.superKeyPressEvent(event),
    }
}
fn menuKey(_: qt.QMenu, event: qt.QKeyEvent) callconv(.c) void {
    if (active) |state| {
        state.search.setFocus();
        key(state.search, event);
    }
}
fn shown(_: qt.QMenu) callconv(.c) void {
    if (active) |state| state.search.setFocus();
}

fn onMenuShow(menu: qt.QMenu, event: qt.QShowEvent) callconv(.c) void {
    menu.superShowEvent(event);
    if (active) |state| {
        // QMenu's screen fitting uses the full unscrolled size hint. Place the
        // bounded popup after that pass so long menus stay inside the launcher.
        menu.move(state.anchor_x, state.anchor_y);
        state.search.setFocus();
    }
}

fn addLabel(menu: qt.QMenu, text: []const u8, name: []const u8) qt.QWidgetAction {
    const label = qt.QLabel.new3(text);
    label.setObjectName(name);
    label.setTextFormat(qt.qnamespace_enums.TextFormat.PlainText);
    label.setMaximumWidth(344);
    const action = qt.QWidgetAction.new(menu);
    action.setDefaultWidget(label);
    menu.addAction(action);
    return action;
}

pub fn show(list: *List, parent: qt.QWidget) void {
    if (active != null) return;
    if (list.selectedEntry() == null) list.selectFirst();
    const entry = list.selectedEntry() orelse return;
    const revision = list.revision;
    var browser: ?browser_actions.Browser = if (entry == .item)
        browser_actions.detect(list.allocator, list.selectedCommand() orelse "") catch null
    else
        null;
    defer if (browser) |*value| value.deinit();
    const menu = qt.QMenu.new(parent);
    defer menu.delete();
    menu.setObjectName("actionMenu");
    const panel_width = @min(380, @max(240, parent.width() - 24));
    menu.setFixedWidth(panel_width);
    menu.setMaximumHeight(@max(160, parent.height() - 144));
    menu.ensurePolished();
    _ = addLabel(menu, "Actions", "actionMenuTitle");
    _ = addLabel(menu, list.selectedName(), "actionMenuContext");
    const search = qt.QLineEdit.new2();
    search.setObjectName("actionMenuSearch");
    search.setPlaceholderText("Search actions...");
    search.setClearButtonEnabled(true);
    const widget = qt.QWidgetAction.new(menu);
    widget.setDefaultWidget(search);
    menu.addAction(widget);
    const empty = addLabel(menu, "No matching actions", "actionMenuEmpty");
    empty.setVisible(false);
    var state = State{ .menu = menu, .search = search, .empty = empty };
    defer {
        for (state.rows.items) |row| std.heap.page_allocator.free(row.label);
        state.rows.deinit(std.heap.page_allocator);
    }
    state.add(if (entry == .window) "Switch to Window" else "Open", "document-open", .open) catch return;
    if (entry == .window) {
        inline for (std.meta.tags(windows.layout.Action)) |action| {
            state.add(action.label(), "preferences-system-windows", .{ .window = action }) catch return;
        }
    }
    if (browser) |value| {
        state.add("New Window", "window-new", .{ .browser = .new_window }) catch return;
        state.add(value.privateLabel(), "view-private", .{ .browser = .private_window }) catch return;
    }
    for (List.currentItemActions(), 0..) |action, i| {
        state.add(action.name, action.icon, .{ .custom = i }) catch return;
    }
    _ = menu.addSeparator();
    state.add(if (entry == .window) "Copy Window Title" else "Copy Name", "edit-copy", .copy_name) catch return;
    if (list.selectedCommand()) |command| {
        if (command.len > 0) state.add("Copy Launch Command", "edit-copy", .copy_command) catch return;
    }
    if (entry == .item) state.add("Application Info", "dialog-information", .information) catch return;
    if (entry == .window or entry == .window_message) state.add("Refresh Windows", "view-refresh", .refresh) catch return;
    _ = addLabel(menu, "↑ ↓  Navigate     ↵  Run     Esc  Close", "actionMenuHint");
    active = &state;
    search.onTextChanged(filter);
    search.onKeyPressEvent(key);
    menu.onAboutToShow(shown);
    menu.onShowEvent(onMenuShow);
    menu.onKeyPressEvent(menuKey);
    menu.setActiveAction(state.rows.items[0].action);
    const size = menu.sizeHint();
    defer size.delete();
    const panel_height = @min(size.height(), menu.maximumHeight());
    const local = qt.QPoint.new4(@max(12, parent.width() - panel_width - 12), @max(12, parent.height() - 56 - panel_height));
    defer local.delete();
    const position = parent.mapToGlobal2(local);
    defer position.delete();
    state.anchor_x = position.x();
    state.anchor_y = position.y();
    const selected = menu.exec2(position);
    active = null;
    if (list.revision != revision) return;
    var chosen = state.chosen;
    if (chosen == null) for (state.rows.items, 0..) |row, i| {
        if (row.action.ptr == selected.ptr) {
            chosen = i;
            break;
        }
    };
    const index = chosen orelse return;
    switch (state.rows.items[index].operation) {
        .open => list.launchSelected(),
        .custom => |i| list.launchAction(i),
        .window => |action| {
            manageWindow(list, entry.window, action) catch |err| {
                _ = qt.QMessageBox.warning(parent, "Window action failed", windows.errorMessage(err));
                return;
            };
            list.launchSelected();
        },
        .browser => |action| if (browser) |*value| {
            value.launch(action) catch |err| {
                @import("utils").log.info("browser action failed: {}", .{err});
                return;
            };
            @import("animation.zig").animateFadeOutAndQuit();
        },
        .copy_name => qt.QApplication.clipboard().setText(list.selectedName()),
        .copy_command => if (list.selectedCommand()) |command| {
            qt.QApplication.clipboard().setText(command);
        },
        .information => {
            info.setup(list, parent);
            info.showInfoPanel();
        },
        .refresh => if (list.on_query_requested) |callback| {
            callback("win:");
        },
    }
}

test "action filtering is case insensitive and literal" {
    try std.testing.expect(matches("Copy File Path", "FILE"));
    try std.testing.expect(matches("Open", ""));
    try std.testing.expect(!matches("Open", "["));
    try std.testing.expect(!matches("Open", "longer query"));
}

test "modal action search filters all rows, copies values and handles Escape" {
    var argc: i32 = 1;
    var arg = [_:0]u8{ 'z', 'e', 'n', 'k', 'a', 'i' };
    var argv = [_][:0]u8{arg[0.. :0]};
    const app = qt.QApplication.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    const theme = if (std.c.getenv("ZENKAI_ACTION_LIGHT") != null) @embedFile("../styles/native-windows-light.qss") else @embedFile("../styles/native-windows-dark.qss");
    const combined = try std.mem.concat(std.testing.allocator, u8, &.{ @embedFile("../styles/main.qss"), theme });
    defer std.testing.allocator.free(combined);
    const qss = try std.mem.replaceOwned(u8, std.testing.allocator, combined, "@ACCENT@", "#f7630c");
    defer std.testing.allocator.free(qss);
    app.setStyleSheet(qss);
    const parent = qt.QWidget.new2();
    defer parent.delete();
    parent.resize(600, 500);
    const actions = [_]@import("list.zig").ListItemAction{.{ .name = "Custom action" }} ** 14;
    const items = [_]@import("list.zig").ListItem{.{ .name = "Brave", .cmd = "brave --profile-directory=Work", .icon = "", .actions = &actions }};
    var list = List.fromItems(std.testing.allocator, &items, 32);
    defer list.view.delete();
    defer list.deinit();
    list.adoptGList();
    List.setOnItemFocused(null);
    list.setFilter("");
    list.selectFirst();
    const Probe = struct {
        var passed = false;
        var cancel = false;
        var positioned = false;
        var window_actions: usize = 0;
        fn run(_: qt.QTimer) callconv(.c) void {
            const state = active orelse return;
            const host = state.menu.parentWidget();
            const origin = qt.QPoint.new4(0, 0);
            defer origin.delete();
            const global = host.mapToGlobal2(origin);
            defer global.delete();
            positioned = state.menu.x() >= global.x() and
                state.menu.x() + state.menu.width() <= global.x() + host.width() and
                state.menu.y() >= global.y() + 80 and
                state.menu.y() + state.menu.height() <= global.y() + host.height() - 48;
            if (cancel) {
                window_actions = 0;
                for (state.rows.items) |row| {
                    if (row.operation == .window) window_actions += 1;
                }
                const event = qt.QKeyEvent.new(6, qt.qnamespace_enums.Key.Key_Escape, 0);
                defer event.delete();
                key(state.search, event);
                return;
            }
            if (std.c.getenv("ZENKAI_ACTION_PREVIEW")) |path| {
                const preview = state.menu.grab();
                defer preview.delete();
                _ = preview.save(std.mem.sliceTo(path, 0));
            }
            state.search.setText("no action has this title");
            passed = state.empty.isVisible();
            state.search.setText("COPY LAUNCH");
            const down = qt.QKeyEvent.new(6, qt.qnamespace_enums.Key.Key_Down, 0);
            defer down.delete();
            key(state.search, down);
            var count: usize = 0;
            var browser_count: usize = 0;
            for (state.rows.items) |row| {
                if (row.action.isVisible()) count += 1;
                if (row.operation == .browser) browser_count += 1;
            }
            passed = passed and !state.empty.isVisible() and count == 1 and browser_count == 2 and state.rows.items.len > 14;
            const event = qt.QKeyEvent.new(6, qt.qnamespace_enums.Key.Key_Return, 0);
            defer event.delete();
            key(state.search, event);
        }
    };
    const timer = qt.QTimer.new();
    defer timer.delete();
    timer.setSingleShot(true);
    timer.onTimeout(Probe.run);
    Probe.cancel = false;
    Probe.passed = false;
    timer.start(0);
    show(&list, parent);
    try std.testing.expect(Probe.passed);
    try std.testing.expect(Probe.positioned);
    try std.testing.expect(!isOpen());
    const copied = qt.QApplication.clipboard().text(std.testing.allocator);
    defer std.testing.allocator.free(copied);
    try std.testing.expectEqualStrings("brave --profile-directory=Work", copied);
    Probe.cancel = true;
    timer.start(0);
    show(&list, parent);
    try std.testing.expect(!isOpen());
    try list.window_search.snapshot.addWithIcon(std.testing.allocator, "invalid", "Test window", "Editor", "");
    list.window_search.cached = true;
    list.setFilter("win: Test");
    list.selectFirst();
    timer.start(0);
    show(&list, parent);
    try std.testing.expectEqual(@as(usize, 7), Probe.window_actions);
}

fn manageWindow(list: *List, index: usize, action: windows.layout.Action) !void {
    var areas: std.ArrayList(windows.layout.Rect) = .empty;
    defer areas.deinit(list.allocator);
    if (comptime @import("builtin").os.tag == .macos) {
        const screens = qt.QGuiApplication.screens(list.allocator);
        defer list.allocator.free(screens);
        for (screens) |screen| {
            const rect = screen.availableGeometry();
            defer rect.delete();
            try areas.append(list.allocator, .{ .x = rect.x(), .y = rect.y(), .width = rect.width(), .height = rect.height() });
        }
    }
    try list.window_search.snapshot.manage(list.allocator, index, action, areas.items);
}
