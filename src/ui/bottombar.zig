const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");
const applist = @import("list.zig");
const ListItemAction = @import("list.zig").ListItemAction;
const info = @import("info.zig");
const lang = @import("lang");

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
        const container = QWidget.new2();
        container.setObjectName("bottomBar");
        container.setMinimumHeight(28);
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
        self.container.onResizeEvent(onContainerResize);

        info.setup(list, self.parent);
        const seq = QKeySequence.new2("Ctrl+I");
        defer seq.delete();
        self.info_shortcut = QShortcut.new2(seq, self.parent);
        self.info_shortcut.onActivated(struct {
            fn handler(_: QShortcut) callconv(.c) void {
                info.showInfoPanel();
            }
        }.handler);
    }

    fn layoutItems(self: *BottomBar) void {
        const cr = self.container.contentsRect();
        const ch = cr.height();
        var x = cr.left();
        for (self.items) |item| {
            item.setFixedHeight(ch);
            item.adjustSize();
            const iw = item.width();
            item.setGeometry(x, cr.top(), iw, ch);
            x += iw + 4;
        }
    }

    fn removeActions(self: *BottomBar) void {
        for (self.actions) |a| a.delete();
        if (self.actions.len > 0) self.allocator.free(self.actions);
        self.actions = &.{};
    }

    fn removeItems(self: *BottomBar) void {
        for (self.items) |item| {
            item.delete();
        }
        if (self.items.len > 0) self.allocator.free(self.items);
        self.items = &.{};
    }

    fn buildAction(self: *BottomBar, icon: QIcon, text: []const u8, shortcut: []const u8, callback: *const fn (QAction) callconv(.c) void) QAction {
        const action = QAction.new6(icon, text, self.parent);
        const seq = QKeySequence.new2(shortcut);
        defer seq.delete();
        action.setShortcut(seq);
        action.onTriggered(callback);
        return action;
    }

    fn buildItem(self: *BottomBar, action: QAction, shortcut_text: []const u8) QWidget {
        const el = QWidget.new2();
        el.setObjectName("actionItem");
        var row = HBoxLayout.new(el);
        row.setContentsMargins(0, 0, 0, 0);
        row.setSpacing(0);

        const button = QToolButton.new2();
        button.setObjectName("actionButton");
        button.setDefaultAction(action);
        button.setToolButtonStyle(qt.qnamespace_enums.ToolButtonStyle.ToolButtonTextBesideIcon);
        row.addWidget(button);

        if (shortcut_text.len > 0) {
            const label = QLabel.new3(shortcut_text);
            label.setObjectName("actionShortcut");
            row.addWidget(label);
        }

        el.setParent(self.container);
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
            const el = QWidget.new2();
            el.setObjectName("actionItem");
            var row = HBoxLayout.new(el);
            row.setContentsMargins(0, 0, 0, 0);
            row.setSpacing(4);

            var buf: [8]u8 = undefined;
            const shortcut_str = if (i < 9)
                std.fmt.bufPrint(&buf, "Ctrl+{d}", .{i + 1}) catch "?"
            else
                std.fmt.bufPrint(&buf, "Ctrl+0", .{}) catch "?";
            const shortcut_label = QLabel.new3(shortcut_str);
            shortcut_label.setObjectName("actionShortcut");
            row.addWidget(shortcut_label);

            const name_label = QLabel.new3(a.name);
            name_label.setObjectName("actionName");
            row.addWidget(name_label);

            el.setParent(self.container);
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
                const icon = QIcon.fromTheme("document-open");
                defer icon.delete();
                self.actions[0] = self.buildAction(icon, lang.get().bottom_bar_open, "", onOpen);
                self.items[0] = self.buildItem(self.actions[0], lang.get().bottom_bar_return);
            }
            {
                const icon = QIcon.fromTheme("dialog-information");
                defer icon.delete();
                self.actions[1] = self.buildAction(icon, lang.get().bottom_bar_info, "", info.onInfo);
                self.items[1] = self.buildItem(self.actions[1], lang.get().bottom_bar_ctrl_i);
            }
        }

        self.layoutItems();
    }
};
