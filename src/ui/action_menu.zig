const std = @import("std");
const qt = @import("libqt6zig");
const List = @import("list.zig").List;
const icons = @import("icon_loader.zig");
const action_icons = @import("action_icons.zig");
const info = @import("info.zig");
const browser_actions = @import("browser_actions.zig");
const windows = @import("../core/window_switcher.zig");
const a = std.heap.page_allocator;
const Operation = union(enum) { open, custom: usize, browser: browser_actions.Action, window: windows.layout.Action, copy_name, copy_command, information, refresh };
const Row = struct { item: qt.QListWidgetItem, label: []const u8, operation: Operation };
fn actionIcon(menu: qt.QWidget, name: []const u8) qt.QIcon {
    if (action_icons.load(menu, name)) |icon| return icon;

    const themed = icons.load(name);
    if (!themed.isNull()) return themed;
    themed.delete();
    return action_icons.load(menu, "application-x-executable") orelse qt.QIcon.new();
}

const State = struct {
    panel: qt.QWidget,
    search: qt.QLineEdit,
    view: qt.QListWidget,
    empty: qt.QLabel,
    list: *List,
    parent: qt.QWidget,
    entry: @import("list.zig").IndexEntry,
    revision: usize,
    browser: ?browser_actions.Browser = null,
    rows: std.ArrayList(Row) = .empty,

    fn add(self: *State, label: []const u8, icon_name: []const u8, operation: Operation) !void {
        const owned = try a.dupe(u8, label);
        errdefer a.free(owned);
        const icon = actionIcon(self.panel, icon_name);
        defer icon.delete();
        const item = qt.QListWidgetItem.new9(icon, label, self.view);
        item.setToolTip(label);
        const size = qt.QSize.new4(0, 38);
        defer size.delete();
        item.setSizeHint(size);
        try self.rows.append(a, .{ .item = item, .label = owned, .operation = operation });
    }
    fn destroy(self: *State) void {
        self.panel.hide();
        self.panel.deleteLater();
        for (self.rows.items) |row| a.free(row.label);
        self.rows.deinit(a);
        if (self.browser) |*browser| browser.deinit();
        a.destroy(self);
    }
};
var active: ?*State = null;
pub var on_visibility_changed: ?*const fn (bool) void = null;

pub fn isOpen() bool {
    return active != null;
}
pub fn selectionMatches() bool {
    const state = active orelse return true;
    const selected = state.list.selectedEntry() orelse return false;
    return state.revision == state.list.revision and std.meta.eql(state.entry, selected);
}
fn detach() ?*State {
    const state = active orelse return null;
    active = null;
    state.panel.hide();
    if (on_visibility_changed) |callback| callback(false);
    return state;
}
pub fn close() void {
    const state = detach() orelse return;
    state.destroy();
}
fn matches(label: []const u8, query: []const u8) bool {
    if (query.len > label.len) return false;
    for (0..label.len - query.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(label[i..][0..query.len], query)) return true;
    }
    return false;
}
fn select(state: *State, index: usize) void {
    state.view.setCurrentRow(@intCast(index));
    state.view.scrollToItem(state.rows.items[index].item);
}
fn filter(_: qt.QLineEdit, value: [*:0]const u8) callconv(.c) void {
    const state = active orelse return;
    var first: ?usize = null;
    for (state.rows.items, 0..) |row, i| {
        const visible = matches(row.label, std.mem.span(value));
        row.item.setHidden(!visible);
        if (visible and first == null) first = i;
    }
    state.empty.setVisible(first == null);
    state.view.setCurrentRow(-1);
    if (first) |index| select(state, index);
}
pub fn navigate(delta: i32) void {
    const state = active orelse return;
    const count = state.rows.items.len;
    if (count == 0) return;
    var index: i32 = state.view.currentRow();
    const step: i32 = if (delta < 0) -1 else 1;
    for (0..@abs(delta)) |_| {
        for (0..count) |_| {
            index = @mod(index + step, @as(i32, @intCast(count)));
            if (!state.rows.items[@intCast(index)].item.isHidden()) {
                select(state, @intCast(index));
                break;
            }
        }
    }
}
pub fn activate() void {
    const state = active orelse return;
    const row = state.view.currentRow();
    if (row >= 0) execute(@intCast(row));
}
pub fn activateCustom(index: usize) void {
    const state = active orelse return;
    for (state.rows.items, 0..) |row, i| {
        if (row.operation == .custom and row.operation.custom == index and !row.item.isHidden()) {
            execute(i);
            return;
        }
    }
}
fn clicked(view: qt.QListWidget, item: qt.QListWidgetItem) callconv(.c) void {
    const row = view.row(item);
    if (row >= 0) execute(@intCast(row));
}
fn key(edit: qt.QLineEdit, event: qt.QKeyEvent) callconv(.c) void {
    const keys = qt.qnamespace_enums.Key;
    switch (event.key()) {
        keys.Key_Escape => close(),
        keys.Key_Return, keys.Key_Enter => activate(),
        keys.Key_Up => navigate(-1),
        keys.Key_Down => navigate(1),
        keys.Key_PageUp => navigate(-8),
        keys.Key_PageDown => navigate(8),
        else => edit.superKeyPressEvent(event),
    }
}
fn makeLabel(parent: qt.QWidget, text: []const u8, name: []const u8) qt.QLabel {
    const widget = qt.QLabel.new5(text, parent);
    widget.setObjectName(name);
    widget.setTextFormat(qt.qnamespace_enums.TextFormat.PlainText);
    widget.setWordWrap(true);
    return widget;
}
pub fn show(list: *List, parent: qt.QWidget) void {
    if (isOpen()) {
        close();
        return;
    }
    if (list.selectedEntry() == null) list.selectFirst();
    const entry = list.selectedEntry() orelse return;
    const content = list.view.parentWidget();
    const panel = qt.QWidget.new(content);
    panel.setObjectName("actionPanel");
    panel.setFixedWidth(@min(270, @divTrunc(parent.width(), 2)));
    const layout = qt.QVBoxLayout.new(panel);
    layout.setContentsMargins(12, 12, 12, 12);
    layout.setSpacing(6);
    layout.addWidget(makeLabel(panel, "Actions", "actionMenuTitle"));
    const context = makeLabel(panel, list.selectedName(), "actionMenuContext");
    context.setMaximumHeight(48);
    context.setToolTip(list.selectedName());
    layout.addWidget(context);
    const search = qt.QLineEdit.new(panel);
    search.setObjectName("actionMenuSearch");
    search.setPlaceholderText("Search actions…");
    search.setClearButtonEnabled(true);
    layout.addWidget(search);
    const empty = makeLabel(panel, "No matching actions", "actionMenuEmpty");
    empty.hide();
    layout.addWidget(empty);
    const view = qt.QListWidget.new(panel);
    view.setObjectName("actionList");
    const icon_size = qt.QSize.new4(24, 24);
    defer icon_size.delete();
    view.setIconSize(icon_size);
    view.setMinimumHeight(0);
    view.setFocusPolicy(qt.qnamespace_enums.FocusPolicy.NoFocus);
    view.setVerticalScrollMode(qt.qabstractitemview_enums.ScrollMode.ScrollPerPixel);
    view.setVerticalScrollBarPolicy(qt.qnamespace_enums.ScrollBarPolicy.ScrollBarAsNeeded);
    view.setHorizontalScrollBarPolicy(qt.qnamespace_enums.ScrollBarPolicy.ScrollBarAlwaysOff);
    view.setTextElideMode(qt.qnamespace_enums.TextElideMode.ElideRight);
    layout.addWidget2(view, 1);
    layout.addWidget(makeLabel(panel, "↑ ↓  Navigate · Enter  Run · Esc  Back", "actionMenuHint"));
    const state = a.create(State) catch {
        panel.deleteLater();
        return;
    };
    state.* = .{ .panel = panel, .search = search, .view = view, .empty = empty, .list = list, .parent = parent, .entry = entry, .revision = list.revision };
    var adopted = false;
    defer if (!adopted) state.destroy();
    state.browser = if (entry == .item) browser_actions.detect(list.allocator, list.selectedCommand() orelse "") catch null else null;
    state.add(if (entry == .window) "Switch to Window" else "Open", "document-open", .open) catch return;
    if (entry == .window) {
        inline for (std.meta.tags(windows.layout.Action)) |action| {
            state.add(action.label(), action.icon(), .{ .window = action }) catch return;
        }
    }
    if (state.browser) |browser| {
        state.add("New Window", "window-new", .{ .browser = .new_window }) catch return;
        state.add(browser.privateLabel(), "view-private", .{ .browser = .private_window }) catch return;
    }
    for (List.currentItemActions(), 0..) |action, i| state.add(action.name, action.icon, .{ .custom = i }) catch return;
    state.add(if (entry == .window) "Copy Window Title" else "Copy Name", "edit-copy", .copy_name) catch return;
    if (list.selectedCommand()) |command| {
        if (command.len > 0) state.add("Copy Launch Command", "edit-copy-command", .copy_command) catch return;
    }
    if (entry == .item) state.add("Application Info", "dialog-information", .information) catch return;
    if (entry == .window or entry == .window_message) state.add("Refresh Windows", "view-refresh", .refresh) catch return;
    active = state;
    adopted = true;
    search.onTextChanged(filter);
    search.onKeyPressEvent(key);
    view.onItemClicked(clicked);
    if (on_visibility_changed) |callback| callback(true);
    content.layout().addWidget(panel);
    panel.show();
    select(state, 0);
    search.setFocus();
}
fn execute(index: usize) void {
    const current = active orelse return;
    if (!selectionMatches()) {
        close();
        return;
    }
    if (index >= current.rows.items.len or current.rows.items[index].item.isHidden()) return;
    const state = detach() orelse return;
    defer state.destroy();
    const list = state.list;
    switch (state.rows.items[index].operation) {
        .open => list.launchSelected(),
        .custom => |i| list.launchAction(i),
        .window => |action| {
            manageWindow(list, state.entry.window, action) catch |err| {
                _ = qt.QMessageBox.warning(state.parent, "Window action failed", windows.errorMessage(err));
                return;
            };
            list.launchSelected();
        },
        .browser => |action| if (state.browser) |*browser| {
            browser.launch(action) catch return;
            @import("animation.zig").animateFadeOutAndQuit();
        },
        .copy_name => qt.QApplication.clipboard().setText(list.selectedName()),
        .copy_command => if (list.selectedCommand()) |command| {
            qt.QApplication.clipboard().setText(command);
        },
        .information => {
            info.setup(list, state.parent);
            info.showInfoPanel();
        },
        .refresh => if (list.on_query_requested) |callback| {
            callback("win:");
        },
    }
}

test "action pane scrolls, filters, executes and rejects stale selections" {
    var argc: i32 = 1;
    var arg = "zenkai".*;
    var argv = [_][:0]u8{&arg};
    const app = qt.QApplication.new(a, &argc, &argv);
    defer app.delete();
    const host = qt.QWidget.new2();
    defer host.delete();
    host.resize(900, 400);
    const layout = qt.QHBoxLayout.new(host);
    const actions: [40]@import("list.zig").ListItemAction = @splat(.{ .name = "Custom action" });
    const items = [_]@import("list.zig").ListItem{.{ .name = "Brave", .cmd = "brave --profile-directory=Work", .icon = "", .actions = &actions }};
    var list = List.fromItems(std.testing.allocator, &items, 32);
    defer list.deinit();
    layout.addWidget(list.view);
    list.adoptGList();
    List.setOnItemFocused(null);
    list.setFilter("");
    list.selectFirst();
    host.show();
    show(&list, host);
    defer close();
    qt.QApplication.processEvents();
    const state = active.?;
    try std.testing.expect(state.panel.parentWidget().ptr == host.ptr);
    try std.testing.expect(state.view.verticalScrollBar().maximum() > 0);
    const pos = qt.QPointF.new5(20, 20);
    defer pos.delete();
    const pixel_delta = qt.QPoint.new4(0, 0);
    defer pixel_delta.delete();
    const angle_delta = qt.QPoint.new4(0, -120);
    defer angle_delta.delete();
    const wheel = qt.QWheelEvent.new(pos, pos, pixel_delta, angle_delta, 0, 0, 0, false);
    defer wheel.delete();
    _ = qt.QApplication.sendEvent(state.view.viewport(), wheel);
    try std.testing.expect(state.view.verticalScrollBar().value() > 0);
    navigate(39);
    qt.QApplication.processEvents();
    try std.testing.expect(state.view.verticalScrollBar().value() > 0);
    state.search.setText("no matching action");
    try std.testing.expect(state.empty.isVisible());
    state.search.setText("COPY LAUNCH");
    activate();
    try std.testing.expect(!isOpen());
    const copied = qt.QApplication.clipboard().text(a);
    defer a.free(copied);
    try std.testing.expectEqualStrings("brave --profile-directory=Work", copied);
    show(&list, host);
    list.setFilter("missing");
    activate();
    try std.testing.expect(!isOpen());
    list.setFilter("");
    list.selectFirst();
    show(&list, host);
    show(&list, host);
    try std.testing.expect(!isOpen());
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
