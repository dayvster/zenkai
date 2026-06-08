const std = @import("std");
const qt = @import("libqt6zig");
const de = @import("desktopapp");
const plugins = @import("plugins");
const utils = @import("utils");
const log = @import("utils").log;

const QListView = qt.QListView;
const QAbstractListModel = qt.QAbstractListModel;
const QModelIndex = qt.QModelIndex;
const QVariant = qt.QVariant;
const QIcon = qt.QIcon;
const QSize = qt.QSize;
const QPixmap = qt.QPixmap;
const QPainter = qt.QPainter;
const QColor = qt.QColor;
const QRect = qt.QRect;
const QFont = qt.QFont;
const QApp = qt.QApplication;

pub const ListItemAction = struct {
    name: []const u8,
    exec: []const u8,
    icon: []const u8,
};

var g_icon_size: i32 = 32;
var g_no_icons: bool = false;

fn loadIcon(icon_name: []const u8) QIcon {
    if (icon_name.len == 0) return QIcon.New();
    if (icon_name[0] == '/') {
        return QIcon.New4(icon_name);
    }
    return QIcon.FromTheme(icon_name);
}

fn loadItemIcon(item: ListItem) QIcon {
    if (item.icon.len > 0) {
        const icon = loadIcon(item.icon);
        if (!icon.IsNull()) return icon;
        icon.Delete();
    }
    const fallback = QIcon.FromTheme("application-x-executable");
    if (!fallback.IsNull()) return fallback;
    fallback.Delete();
    return makeFallbackIcon(item.name);
}

fn makeFallbackIcon(name: []const u8) QIcon {
    const palette = [_][3]u8{
        .{ 0xe5, 0x6b, 0x6b },
        .{ 0xe8, 0x8d, 0x67 },
        .{ 0xe9, 0xc4, 0x6a },
        .{ 0xa3, 0xbe, 0x8c },
        .{ 0x7e, 0xb3, 0xd1 },
        .{ 0x9b, 0x8e, 0xd3 },
        .{ 0xd4, 0x8b, 0xbd },
        .{ 0x8c, 0xbe, 0xb5 },
    };

    const first = if (name.len > 0) std.ascii.toUpper(name[0]) else '?';
    const idx = @as(usize, @intCast(first)) % palette.len;
    const c = palette[idx];

    const bg = QColor.New5(c[0], c[1], c[2]);
    defer bg.Delete();

    const luminance = @as(f32, @floatFromInt(c[0])) * 0.299 +
        @as(f32, @floatFromInt(c[1])) * 0.587 +
        @as(f32, @floatFromInt(c[2])) * 0.114;
    const text_color = if (luminance > 128.0)
        QColor.New5(0, 0, 0)
    else
        QColor.New5(255, 255, 255);
    defer text_color.Delete();

    var pixmap = QPixmap.New2(g_icon_size, g_icon_size);
    defer pixmap.Delete();
    pixmap.Fill1(bg);

    var painter = QPainter.New();
    defer painter.Delete();
    _ = painter.Begin(pixmap);
    defer _ = painter.End();

    painter.SetRenderHint(1);
    painter.SetPen(text_color);

    const border = @divTrunc(g_icon_size, 10);
    const radius = @as(f64, @floatFromInt(g_icon_size)) / 3.0;
    const iw = g_icon_size - 2 * border;
    painter.DrawRoundedRect2(border, border, iw, iw, radius, radius);

    var font = QFont.New2("sans-serif");
    defer font.Delete();
    font.SetPixelSize(g_icon_size - @divTrunc(g_icon_size, 4));
    font.SetBold(true);
    painter.SetFont(font);

    var rect = QRect.New6(0, 0, g_icon_size, g_icon_size);
    defer rect.Delete();

    var letter: [2]u8 = .{ first, 0 };
    painter.DrawText6(rect, 132, letter[0..1]);

    return QIcon.New2(pixmap);
}

fn tryLoadIcon(app: de.DesktopApp) QIcon {
    if (app.icon) |icon_name| {
        if (icon_name.len > 0) {
            const icon = loadIcon(icon_name);
            if (!icon.IsNull()) return icon;
            icon.Delete();
        }
        const fallback = QIcon.FromTheme("application-x-executable");
        if (!fallback.IsNull()) return fallback;
        fallback.Delete();
    }
    return makeFallbackIcon(app.name);
}

fn tryLoadPluginIcon(icon_name: []const u8) QIcon {
    if (icon_name.len > 0) {
        const icon = loadIcon(icon_name);
        if (!icon.IsNull()) return icon;
        icon.Delete();
    }
    const fallback = QIcon.FromTheme("application-x-executable");
    if (!fallback.IsNull()) return fallback;
    fallback.Delete();
    return makeFallbackIcon("pl");
}

pub const ListItem = struct {
    icon: []const u8,
    cmd: []const u8,
    name: []const u8,
    actions: []const ListItemAction = &.{},
    desktop_app_idx: ?usize = null,
};

const DataSource = union(enum) {
    desktop_apps: []const de.DesktopApp,
    items: []const ListItem,
};

pub const IndexEntry = union(enum) {
    item: usize,
    plugin: usize,
};

fn freePluginResults(allocator: std.mem.Allocator, results: *std.ArrayList(plugins.PluginResult)) void {
    for (results.items) |plugin_result| {
        allocator.free(plugin_result.title);
        allocator.free(plugin_result.subtitle);
        allocator.free(plugin_result.icon);
    }
    results.clearRetainingCapacity();
}

var g_list: *List = undefined;
var g_on_item_focused: ?*const fn (item_index: usize, actions: []const ListItemAction) void = null;
var g_current_item_actions: []const ListItemAction = &.{};

fn onCurrentChanged(_: QListView, current: QModelIndex, _: QModelIndex) callconv(.c) void {
    const row = current.Row();
    if (row < 0) return;
    const urow = @as(usize, @intCast(row));
    if (urow >= g_list.indices.items.len) return;

    const entry = g_list.indices.items[urow];
    switch (entry) {
        .item => |item_idx| {
            const items = switch (g_list.source) {
                .items => |is| is,
                .desktop_apps => return,
            };
            g_current_item_actions = items[item_idx].actions;
            if (g_on_item_focused) |cb| cb(item_idx, items[item_idx].actions);
        },
        .plugin => {
            g_current_item_actions = &.{};
            if (g_on_item_focused) |cb| cb(0, &.{});
        },
    }
}

fn onRowCount(_: QAbstractListModel, _: QModelIndex) callconv(.c) i32 {
    return @intCast(g_list.indices.items.len);
}

fn onData(
    _: QAbstractListModel,
    index: QModelIndex,
    role: i32,
) callconv(.c) QVariant {
    const row = index.Row();
    const indices = g_list.indices.items;
    if (row < 0 or @as(usize, @intCast(row)) >= indices.len)
        return QVariant.New();

    const entry = indices[@as(usize, @intCast(row))];

    switch (entry) {
        .item => |idx| {
            if (role == 0) {
                const name = switch (g_list.source) {
                    .desktop_apps => |apps| apps[idx].name,
                    .items => |items| items[idx].name,
                };
                return QVariant.New24(name);
            }
            if (role == 1) {
                if (g_no_icons) return QVariant.New();
                const icon = switch (g_list.source) {
                    .desktop_apps => |apps| tryLoadIcon(apps[idx]),
                    .items => |items| loadItemIcon(items[idx]),
                };
                defer icon.Delete();
                return icon.ToQVariant();
            }
        },
        .plugin => |plugin_idx| {
            const plugin_result = &g_list.plugin_results.items[plugin_idx];
            if (role == 0) return QVariant.New24(plugin_result.title);
            if (role == 1) {
                if (g_no_icons) return QVariant.New();
                const icon = tryLoadPluginIcon(plugin_result.icon);
                defer icon.Delete();
                return icon.ToQVariant();
            }
        },
    }

    return QVariant.New();
}

pub const List = struct {
    allocator: std.mem.Allocator,
    view: QListView,
    model: QAbstractListModel,
    source: DataSource,
    indices: std.ArrayList(IndexEntry),
    plugin_results: std.ArrayList(plugins.PluginResult),
    plugin_manager: ?*plugins.PluginManager,

    pub fn init(allocator: std.mem.Allocator, apps: []const de.DesktopApp, icon_size: i32, plugin_manager: ?*plugins.PluginManager) List {
        g_icon_size = icon_size;
        return initInternal(allocator, .{ .desktop_apps = apps }, icon_size, plugin_manager);
    }

    pub fn fromItems(allocator: std.mem.Allocator, items: []const ListItem, icon_size: i32) List {
        g_icon_size = icon_size;
        return initInternal(allocator, .{ .items = items }, icon_size, null);
    }

    fn initInternal(allocator: std.mem.Allocator, source: DataSource, icon_size: i32, plugin_manager: ?*plugins.PluginManager) List {
        g_icon_size = icon_size;

        var model = QAbstractListModel.New();
        model.OnRowCount(onRowCount);
        model.OnData(onData);

        var view = QListView.New2();
        var icon_sz = QSize.New4(icon_size, icon_size);
        defer icon_sz.Delete();
        view.SetIconSize(icon_sz);
        view.SetModel(model);
        view.OnCurrentChanged(onCurrentChanged);

        return .{
            .allocator = allocator,
            .view = view,
            .model = model,
            .source = source,
            .indices = std.ArrayList(IndexEntry).empty,
            .plugin_results = std.ArrayList(plugins.PluginResult).empty,
            .plugin_manager = plugin_manager,
        };
    }

    pub fn setOnItemFocused(callback: *const fn (item_index: usize, actions: []const ListItemAction) void) void {
        g_on_item_focused = callback;
    }

    pub fn currentItemActions() []const ListItemAction {
        return g_current_item_actions;
    }

    fn sourceLen(self: *const List) usize {
        return switch (self.source) {
            .desktop_apps => |apps| apps.len,
            .items => |items| items.len,
        };
    }

    fn sourceName(self: *const List, idx: usize) []const u8 {
        return switch (self.source) {
            .desktop_apps => |apps| apps[idx].name,
            .items => |items| items[idx].name,
        };
    }

    pub fn setFilter(self: *List, text: []const u8) void {
        freePluginResults(self.allocator, &self.plugin_results);
        self.indices.clearRetainingCapacity();

        const count = self.sourceLen();
        if (text.len == 0) {
            for (0..count) |i|
                self.indices.append(self.allocator, IndexEntry{ .item = i }) catch |err| log.info("OOM in setFilter: {}", .{err});
        } else {
            var lower_text_buf: [256]u8 = undefined;
            const lower_text = if (text.len <= lower_text_buf.len) blk: {
                for (text, 0..) |c, i| lower_text_buf[i] = std.ascii.toLower(c);
                break :blk lower_text_buf[0..text.len];
            } else text;

            const max_distance: usize = if (text.len < 3) 0 else 3;

            for (0..count) |i| {
                const name = self.sourceName(i);
                var lower_name_buf: [256]u8 = undefined;
                var matches = false;

                if (name.len <= lower_name_buf.len) {
                    for (name, 0..) |c, j| lower_name_buf[j] = std.ascii.toLower(c);
                    const lower_name = lower_name_buf[0..name.len];

                    if (std.mem.indexOf(u8, lower_name, lower_text) != null) {
                        matches = true;
                    }

                    if (!matches and max_distance > 0) {
                        const dist = utils.demerauLevenshteinDistance(self.allocator, lower_text, lower_name, max_distance) catch max_distance;
                        if (dist < max_distance) {
                            matches = true;
                        }
                    }
                }

                if (matches) {
                    self.indices.append(self.allocator, IndexEntry{ .item = i }) catch |err| log.info("OOM in setFilter: {}", .{err});
                }
            }
        }

        if (self.plugin_manager) |plugin_manager| {
            if (text.len > 0) {
                plugin_manager.queryAll(text, &self.plugin_results);
                for (0..self.plugin_results.items.len) |plugin_index| {
                    self.indices.append(self.allocator, IndexEntry{ .plugin = plugin_index }) catch |err| log.info("OOM in setFilter: {}", .{err});
                }
            }
        }

        g_list = self;
        self.model.BeginResetModel();
        self.model.EndResetModel();

        self.selectFirst();
    }

    pub fn invalidIndex() QModelIndex {
        return QModelIndex.New3();
    }

    pub fn selectFirst(self: *List) void {
        if (self.indices.items.len > 0) {
            self.selectRow(0);
        }
    }

    pub fn selectRow(self: *List, row: i32) void {
        var invalid = List.invalidIndex();
        defer invalid.Delete();
        var idx = self.model.Index(row, 0, invalid);
        defer idx.Delete();
        self.view.SetCurrentIndex(idx);
    }

    pub fn launchSelected(self: *List) void {
        var idx = self.view.CurrentIndex();
        defer idx.Delete();
        if (!idx.IsValid()) {
            self.selectFirst();
            return;
        }
        const row = @as(usize, @intCast(idx.Row()));
        if (row >= self.indices.items.len) return;

        switch (self.indices.items[row]) {
            .item => |item_idx| {
                switch (self.source) {
                    .desktop_apps => |apps| {
                        const app = &apps[item_idx];
                        const expanded = app.expandExec(self.allocator) catch return;
                        defer self.allocator.free(expanded);
                        utils.execute(expanded, self.allocator) catch {};
                    },
                    .items => |items| {
                        utils.execute(items[item_idx].cmd, self.allocator) catch {};
                    },
                }
            },
            .plugin => |plugin_result_index| {
                const plugin_result = &self.plugin_results.items[plugin_result_index];
                if (self.plugin_manager) |plugin_manager| plugin_manager.handleSelect(plugin_result.plugin_index, plugin_result.id);
            },
        }
        QApp.Quit();
    }

    pub fn setNoIcons(v: bool) void {
        g_no_icons = v;
    }

    pub fn deinit(self: *List) void {
        freePluginResults(self.allocator, &self.plugin_results);
        self.plugin_results.deinit(self.allocator);
        self.model.Delete();
        self.indices.deinit(self.allocator);
    }
};
