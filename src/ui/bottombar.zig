const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");

const applist = @import("list.zig");
const ListItemAction = @import("list.zig").ListItemAction;
const info = @import("info.zig");
const lang = @import("lang");
const action_icons = @import("action_icons.zig");

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

// Line icons on a 24px grid, drawn in the theme's text color (`currentColor`).
const icon_attributes = "xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"";
/// Open: an arrow leaving a box.
pub const open_icon = "<svg " ++ icon_attributes ++ "><path d=\"M14 4h6v6M20 4l-8.5 8.5\"/><path d=\"M18 13.5V18a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4.5\"/></svg>";
/// Actions: a lightning bolt.
pub const actions_icon = "<svg " ++ icon_attributes ++ "><path d=\"M13 3 5 13.5h6L10 21l8-10.5h-6L13 3Z\"/></svg>";
/// The Return key: an arrow turning left.
const return_icon = "<svg " ++ icon_attributes ++ "><path d=\"M20 5v6.5a3 3 0 0 1-3 3H5\"/><path d=\"m9 10.5-4 4 4 4\"/></svg>";

/// How an item's shortcut is shown: the Return key as an arrow icon and its name, anything
/// else ("Ctrl+K") as one key per part.
pub const Keys = union(enum) {
    enter,
    combo: []const u8,
};

/// The `#rrggbb` of a palette role on `widget`, after its style sheet has been applied. The
/// palette and its colors are references owned by the widget, so nothing is deleted.
fn roleColor(widget: anytype, role: i32, out: *[7]u8) []const u8 {
    widget.ensurePolished();
    const color = widget.palette().color2(role);
    return std.fmt.bufPrint(out, "#{x:0>2}{x:0>2}{x:0>2}", .{
        @as(u8, @intCast(color.red())),
        @as(u8, @intCast(color.green())),
        @as(u8, @intCast(color.blue())),
    }) catch unreachable;
}

/// Gives `button` a line icon in its own text color. The button must already be inside the
/// widget the theme styles (#bottomBar), so the color is the theme's.
pub fn tintButton(button: QToolButton, action: QAction, svg: []const u8) void {
    var hex: [7]u8 = undefined;
    const color = roleColor(button, qt.qpalette_enums.ColorRole.ButtonText, &hex);
    const icon = action_icons.tinted(button, svg, color) orelse return;
    defer icon.delete();
    action.setIcon(icon);
}

/// Adds an item's shortcut to `row`. The row's widget must already sit in #bottomBar so the
/// labels get the theme's muted color. No borders: Return is its name and an arrow, other
/// keys are small filled keycaps (#actionKey).
pub fn addShortcut(row: HBoxLayout, keys: Keys) void {
    switch (keys) {
        .enter => {
            const name = QLabel.new3(lang.get().bottom_bar_return);
            name.setObjectName("actionShortcut");
            row.addWidget(name);
            const arrow = QLabel.new3("");
            arrow.setObjectName("actionShortcut");
            row.addWidget(arrow);
            var hex: [7]u8 = undefined;
            const color = roleColor(arrow, qt.qpalette_enums.ColorRole.WindowText, &hex);
            const icon = action_icons.tinted(arrow, return_icon, color) orelse return;
            defer icon.delete();
            const pixmap = icon.pixmap2(14, 14);
            defer pixmap.delete();
            arrow.setPixmap(pixmap);
        },
        .combo => |shortcut| {
            var parts = std.mem.splitScalar(u8, shortcut, '+');
            while (parts.next()) |part| {
                const key = QLabel.new3(part);
                key.setObjectName("actionKey");
                // Centred at their own height instead of stretching to the item's.
                row.addWidget3(key, 0, qt.qnamespace_enums.AlignmentFlag.AlignVCenter);
            }
        },
    }
}

pub const Action = struct {
    icon: QIcon,
    text: []const u8,
    shortcut: []const u8,
    callback: *const fn (QAction) callconv(.c) void,
};

fn onOpen(_: QAction) callconv(.c) void {
    g_app_list.launchSelected();
}

fn onActions(_: QAction) callconv(.c) void {
    @import("action_menu.zig").show(g_app_list, g_bar.parent);
}

fn onContainerResize(_: QWidget, _: QResizeEvent) callconv(.c) void {
    g_bar.layoutItems();
}

pub const BottomBar = struct {
    pub const minimum_height = 44;

    allocator: std.mem.Allocator,
    container: QWidget,
    actions: []QAction,
    items: []QWidget,
    parent: QWidget,
    info_shortcut: QShortcut,
    menu_button: ?QToolButton = null,

    pub fn init(allocator: std.mem.Allocator, parent: qt.QWidget, vis: config.VisualConfig) BottomBar {
        _ = vis;
        const container = QWidget.new2();
        container.setObjectName("bottomBar");
        container.setFixedHeight(minimum_height);
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
        var x = cr.left() + 8;
        for (self.items, 0..) |item, i| {
            item.setFixedHeight(@max(ch - 12, 0));
            item.adjustSize();
            const iw = item.width();
            const item_x = if (i == self.items.len - 1 and i > 0)
                @max(x, cr.right() - iw - 8)
            else
                x;
            item.setGeometry(item_x, cr.top() + 6, iw, @max(ch - 12, 0));
            item.show();
            x += iw + 12;
        }
    }

    fn removeActions(self: *BottomBar) void {
        for (self.actions) |a| a.delete();
        if (self.actions.len > 0) self.allocator.free(self.actions);
        self.actions = &.{};
    }

    fn removeItems(self: *BottomBar) void {
        self.menu_button = null;
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

    /// `svg` replaces the action's icon with a line icon in the theme's text color.
    fn buildItem(self: *BottomBar, action: QAction, keys: Keys, svg: ?[]const u8) QWidget {
        const el = QWidget.new2();
        el.setObjectName("actionItem");
        // Parent first so the theme's #bottomBar rules reach the labels and icons below.
        el.setParent(self.container);
        var row = HBoxLayout.new(el);
        row.setContentsMargins(0, 0, 0, 0);
        row.setSpacing(6);

        const button = QToolButton.new2();
        button.setObjectName("actionButton");
        button.setDefaultAction(action);
        self.menu_button = button;
        button.setFocusPolicy(qt.qnamespace_enums.FocusPolicy.NoFocus);
        button.setToolButtonStyle(qt.qnamespace_enums.ToolButtonStyle.ToolButtonTextBesideIcon);
        row.addWidget(button);
        if (svg) |icon| tintButton(button, action, icon);

        switch (keys) {
            .combo => |shortcut| if (shortcut.len > 0) addShortcut(row, keys),
            .enter => addShortcut(row, keys),
        }
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
        _ = actions;
        self.setDefaultActions();
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
                self.items[i] = self.buildItem(self.actions[i], .{ .combo = a.shortcut }, null);
            }
        } else {
            const no_icon = QIcon.new();
            defer no_icon.delete();
            self.actions[0] = self.buildAction(no_icon, lang.get().bottom_bar_open, "", onOpen);
            self.items[0] = self.buildItem(self.actions[0], .enter, open_icon);
            self.actions[1] = self.buildAction(no_icon, lang.get().bottom_bar_actions, "", onActions);
            self.items[1] = self.buildItem(self.actions[1], .{ .combo = "Ctrl+K" }, actions_icon);
        }

        self.layoutItems();
    }
};
