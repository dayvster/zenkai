const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");
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
const QResizeEvent = qt.QResizeEvent;

var g_app_list: *applist.List = undefined;
var g_bar: *BottomBar = undefined;

pub const Action = struct {
    icon: QIcon,
    text: []const u8,
    shortcut: []const u8,
    callback: *const fn (QAction) callconv(.c) void,
};

fn onOpen(_: QAction) callconv(.c) void {
    g_app_list.launchSelected();
}

fn onContainerResize(_: QWidget, _: QResizeEvent) callconv(.c) void {
    g_bar.layoutItems();
}

pub const BottomBar = struct {
    allocator: std.mem.Allocator,
    container: QWidget,
    actions: []QAction,
    items: []QWidget,
    parent: QWidget,
    info_shortcut: QShortcut,

    pub fn init(allocator: std.mem.Allocator, parent: qt.QWidget, vis: config.VisualConfig) BottomBar {
        _ = vis;
        const container = QWidget.New2();
        container.SetObjectName("bottomBar");
        container.SetMinimumHeight(28);
        return .{
            .allocator = allocator,
            .container = container,
            .actions = &.{},
            .items = &.{},
            .parent = parent,
            .info_shortcut = undefined,
        };
    }

    pub fn setup(self: *BottomBar, list: *applist.List) void {
        g_app_list = list;
        g_bar = self;
        self.container.OnResizeEvent(onContainerResize);

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

    fn layoutItems(self: *BottomBar) void {
        const cr = self.container.ContentsRect();
        const ch = cr.Height();
        var x = cr.Left();
        for (self.items) |item| {
            item.SetFixedHeight(ch);
            item.AdjustSize();
            const iw = item.Width();
            item.SetGeometry(x, cr.Top(), iw, ch);
            x += iw + 4;
        }
    }

    fn removeActions(self: *BottomBar) void {
        for (self.actions) |a| a.Delete();
        if (self.actions.len > 0) self.allocator.free(self.actions);
        self.actions = &.{};
    }

    fn removeItems(self: *BottomBar) void {
        for (self.items) |item| {
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
        el.SetObjectName("actionItem");
        var row = HBoxLayout.New(el);
        row.SetContentsMargins(0, 0, 0, 0);
        row.SetSpacing(0);

        const button = QToolButton.New2();
        button.SetObjectName("actionButton");
        button.SetDefaultAction(action);
        button.SetToolButtonStyle(qt.qnamespace_enums.ToolButtonStyle.ToolButtonTextBesideIcon);
        row.AddWidget(button);

        if (shortcut_text.len > 0) {
            const label = QLabel.New3(shortcut_text);
            label.SetObjectName("actionShortcut");
            row.AddWidget(label);
        }

        el.SetParent(self.container);
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
            el.SetObjectName("actionItem");
            var row = HBoxLayout.New(el);
            row.SetContentsMargins(0, 0, 0, 0);
            row.SetSpacing(4);

            var buf: [8]u8 = undefined;
            const shortcut_str = if (i < 9)
                std.fmt.bufPrint(&buf, "Ctrl+{d}", .{i + 1}) catch "?"
            else
                std.fmt.bufPrint(&buf, "Ctrl+0", .{}) catch "?";
            const shortcut_label = QLabel.New3(shortcut_str);
            shortcut_label.SetObjectName("actionShortcut");
            row.AddWidget(shortcut_label);

            const name_label = QLabel.New3(a.name);
            name_label.SetObjectName("actionName");
            row.AddWidget(name_label);

            el.SetParent(self.container);
            self.items[i] = el;
        }

        self.layoutItems();
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

        self.layoutItems();
    }
};
