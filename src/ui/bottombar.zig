const std = @import("std");
const qt = @import("libqt6zig");
const applist = @import("list.zig");
const ListItemAction = @import("list.zig").ListItemAction;
const info = @import("info.zig");

const HBoxLayout = qt.QHBoxLayout;
const QAction = qt.QAction;
const QToolButton = qt.QToolButton;
const QShortcut = qt.QShortcut;
const QKeySequence = qt.QKeySequence;
const QIcon = qt.QIcon;
const QLabel = qt.QLabel;
const QWidget = qt.QWidget;

var g_app_list: *applist.List = undefined;

pub const Action = struct {
    icon: QIcon,
    text: []const u8,
    shortcut: []const u8,
    callback: *const fn (QAction) callconv(.c) void,
};

fn onOpen(_: QAction) callconv(.c) void {
    g_app_list.launchSelected();
}

pub const BottomBar = struct {
    allocator: std.mem.Allocator,
    layout: HBoxLayout,
    container: QWidget,
    actions: []QAction,
    items: []QWidget,
    parent: QWidget,
    info_shortcut: QShortcut,

    pub fn init(allocator: std.mem.Allocator, parent: qt.QWidget) BottomBar {
        const container = QWidget.New2();
        const layout = qt.QHBoxLayout.New(container);
        layout.SetContentsMargins(8, 4, 8, 4);
        layout.SetSpacing(4);
        layout.AddStretch();
        return .{
            .allocator = allocator,
            .layout = layout,
            .container = container,
            .actions = &.{},
            .items = &.{},
            .parent = parent,
            .info_shortcut = undefined,
        };
    }

    pub fn setup(self: *BottomBar, list: *applist.List) void {
        g_app_list = list;
        info.setup(list, self.parent);
        const seq = QKeySequence.New2("Ctrl+I");
        defer seq.Delete();
        self.info_shortcut = QShortcut.New2(seq, self.parent);
        self.info_shortcut.OnActivated(struct {
            fn handler(_: QShortcut) callconv(.c) void {
                info.showInfoPanel();
            }
        }.handler);
    }

    fn removeActions(self: *BottomBar) void {
        for (self.actions) |a| a.Delete();
        if (self.actions.len > 0) self.allocator.free(self.actions);
        self.actions = &.{};
    }

    fn removeItems(self: *BottomBar) void {
        for (self.items) |item| {
            self.layout.RemoveWidget(item);
            item.Delete();
        }
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = &.{};
    }

    fn buildAction(self: *BottomBar, icon: QIcon, text: []const u8, shortcut: []const u8, callback: *const fn (QAction) callconv(.c) void) QAction {
        const action = QAction.New6(icon, text, self.parent);
        const seq = QKeySequence.New2(shortcut);
        defer seq.Delete();
        action.SetShortcut(seq);
        action.OnTriggered(callback);
        return action;
    }

    fn buildItem(self: *BottomBar, action: QAction, shortcut_text: []const u8) QWidget {
        const el = QWidget.New2();
        var row = HBoxLayout.New(el);
        row.SetContentsMargins(0, 0, 0, 0);
        row.SetSpacing(0);

        const button = QToolButton.New2();
        button.SetDefaultAction(action);
        button.SetToolButtonStyle(qt.qnamespace_enums.ToolButtonStyle.ToolButtonTextBesideIcon);
        row.AddWidget(button);

        if (shortcut_text.len > 0) {
            const label = QLabel.New3(shortcut_text);
            row.AddWidget(label);
        }

        self.layout.AddWidget(el);
        return el;
    }

    pub fn deinit(self: *BottomBar) void {
        self.removeItems();
        self.removeActions();
    }

    pub fn setDefaultActions(self: *BottomBar) void {
        self.setActions(&.{});
    }

    pub fn setItemActions(self: *BottomBar, actions: []const ListItemAction) void {
        self.removeItems();
        self.removeActions();

        const n = @min(actions.len, 10);
        if (n == 0) {
            self.setDefaultActions();
            return;
        }

        self.actions = &.{};
        self.items = self.allocator.alloc(QWidget, n) catch return;

        for (actions[0..n], 0..) |a, i| {
            const el = QWidget.New2();
            var row = HBoxLayout.New(el);
            row.SetContentsMargins(0, 0, 0, 0);
            row.SetSpacing(4);

            var buf: [8]u8 = undefined;
            const shortcut_str = if (i < 9)
                std.fmt.bufPrint(&buf, "Ctrl+{d}", .{i + 1}) catch "?"
            else
                std.fmt.bufPrint(&buf, "Ctrl+0", .{}) catch "?";
            const shortcut_label = QLabel.New3(shortcut_str);
            row.AddWidget(shortcut_label);

            const name_label = QLabel.New3(a.name);
            row.AddWidget(name_label);

            self.layout.AddWidget(el);
            self.items[i] = el;
        }
    }

    pub fn setActions(self: *BottomBar, actions: []const Action) void {
        self.removeItems();
        self.removeActions();

        const n = if (actions.len > 0) actions.len else @as(usize, 2);
        self.actions = self.allocator.alloc(QAction, n) catch return;
        self.items = self.allocator.alloc(QWidget, n) catch {
            self.allocator.free(self.actions);
            self.actions = &.{};
            return;
        };

        if (actions.len > 0) {
            for (actions, 0..) |a, i| {
                self.actions[i] = self.buildAction(a.icon, a.text, a.shortcut, a.callback);
                self.items[i] = self.buildItem(self.actions[i], a.shortcut);
            }
        } else {
            {
                const icon = QIcon.FromTheme("document-open");
                defer icon.Delete();
                self.actions[0] = self.buildAction(icon, "Open", "", onOpen);
                self.items[0] = self.buildItem(self.actions[0], "Return");
            }
            {
                const icon = QIcon.FromTheme("dialog-information");
                defer icon.Delete();
                self.actions[1] = self.buildAction(icon, "Info", "", info.onInfo);
                self.items[1] = self.buildItem(self.actions[1], "Ctrl+I");
            }
        }
    }
};
