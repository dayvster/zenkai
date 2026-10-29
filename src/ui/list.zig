const std = @import("std");
const qt = @import("libqt6zig");
const utils = @import("utils");
const plugins = @import("plugins");
const de = @import("desktopapp");
const freq = @import("core_freq");
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
const animation = @import("animation.zig");
const icon_loader = @import("icon_loader.zig");
const benchmark = @import("../debug/startup_benchmark.zig");
const window_search = @import("../core/window_search.zig");

pub const ListItemAction = plugins.ResultAction;

test "native default browser descriptor loads an application icon" {
    if (@import("builtin").os.tag != .windows) return;
    const descriptor = utils.app_icons.browser(std.testing.allocator, "https") catch |err| switch (err) {
        error.NoAssociation => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(descriptor);
    var argc: i32 = 1;
    var arg = [_:0]u8{ 'z', 'e', 'n', 'k', 'a', 'i' };
    var argv = [_][:0]u8{arg[0.. :0]};
    const app = QApp.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    const icon = icon_loader.load(descriptor);
    defer icon.delete();
    try std.testing.expect(!icon.isNull());
    const pixmap = icon.pixmap2(32, 32);
    defer pixmap.delete();
    try std.testing.expect(!pixmap.isNull());
}

test "layout leaves icons unloaded; painting, scrolling and filtering populate the right entries" {
    const a = std.testing.allocator;
    var argc: i32 = 1;
    var arg = [_:0]u8{ 'z', 'e', 'n', 'k', 'a', 'i' };
    var argv = [_][:0]u8{arg[0.. :0]};
    const app = QApp.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    var items: [200]ListItem = undefined;
    for (&items) |*item| item.* = .{ .name = "Application", .cmd = "", .icon = "" };
    items[199].name = "Unique target";
    List.setNoIcons(false);
    defer List.setNoIcons(false);
    var list = List.fromItems(a, &items, 32);
    defer list.view.delete();
    defer list.deinit();
    list.adoptGList();
    const PaintProbe = struct {
        var calls: usize = 0;
        fn afterPaint() void {
            calls += 1;
        }
    };
    PaintProbe.calls = 0;
    list.after_first_paint = PaintProbe.afterPaint;
    list.view.resize(400, 240);
    list.setFilter("");
    var invalid = List.invalidIndex();
    defer invalid.delete();
    for (0..items.len) |row| {
        const index = list.model.index(@intCast(row), 0, invalid);
        defer index.delete();
        const decoration = onData(list.model, index, 1);
        decoration.delete();
    }
    try std.testing.expectEqual(@as(u32, 0), list.item_icons.count());
    try std.testing.expectEqual(@as(usize, 0), PaintProbe.calls);
    list.view.show();
    QApp.processEvents();
    list.view.viewport().repaint();
    try std.testing.expect(list.item_icons.count() > 0);
    try std.testing.expectEqual(@as(usize, 1), PaintProbe.calls);
    try std.testing.expect(list.item_icons.count() < 30);
    try std.testing.expect(!list.item_icons.contains(199));
    const first_count = list.item_icons.count();
    list.view.viewport().repaint();
    try std.testing.expectEqual(first_count, list.item_icons.count());
    try std.testing.expectEqual(@as(usize, 1), PaintProbe.calls);
    list.selectRow(199);
    QApp.processEvents();
    list.view.viewport().repaint();
    try std.testing.expect(list.item_icons.contains(199));
    list.invalidateIcons();
    list.setFilter("Unique target");
    QApp.processEvents();
    list.view.viewport().repaint();
    try std.testing.expectEqual(@as(u32, 1), list.item_icons.count());
    try std.testing.expect(list.item_icons.contains(199));
    list.invalidateIcons();
    List.setNoIcons(true);
    list.setFilter("");
    QApp.processEvents();
    list.view.viewport().repaint();
    try std.testing.expectEqual(@as(u32, 0), list.item_icons.count());
}

var g_icon_size: i32 = 32;

test "window rows work without Lua, retain errors, and obey the disable flag" {
    const a = std.testing.allocator;
    var argc: i32 = 1;
    var arg = [_:0]u8{ 'z', 'e', 'n', 'k', 'a', 'i' };
    var argv = [_][:0]u8{arg[0.. :0]};
    const app = QApp.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    var list = List.fromItems(a, &.{}, 32);
    defer list.view.delete();
    defer list.deinit();
    list.adoptGList();
    try list.window_search.snapshot.addWithIcon(a, "invalid", "Editor project", "Editor", "application-x-executable");
    list.window_search.cached = true;
    list.setFilter("WIN: editor");
    try std.testing.expect(list.plugin_manager == null);
    try std.testing.expectEqual(@as(usize, 1), list.indices.items.len);
    try std.testing.expect(list.indices.items[0] == .window);
    try std.testing.expectEqual(@as(u32, 0), list.window_icons.count());
    list.selectFirst();
    list.launchSelected();
    try std.testing.expect(list.indices.items[0] == .window_message);
    try std.testing.expect(list.window_search.message != null);
    list.window_search.enabled = false;
    list.setFilter("win:");
    try std.testing.expectEqual(@as(usize, 0), list.indices.items.len);
    try std.testing.expect(!list.window_search.active);
}
var g_no_icons: bool = false;

fn loadIcon(icon_name: []const u8) QIcon {
    return icon_loader.load(icon_name);
}

fn loadItemIcon(item: ListItem) QIcon {
    if (item.icon.len > 0) {
        const icon = loadIcon(item.icon);
        if (!icon.isNull()) return icon;
        icon.delete();
    }
    const fallback = QIcon.fromTheme("application-x-executable");
    if (!fallback.isNull()) return fallback;
    fallback.delete();
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

    const bg = QColor.new5(c[0], c[1], c[2]);
    defer bg.delete();

    const luminance = @as(f32, @floatFromInt(c[0])) * 0.299 +
        @as(f32, @floatFromInt(c[1])) * 0.587 +
        @as(f32, @floatFromInt(c[2])) * 0.114;
    const text_color = if (luminance > 128.0)
        QColor.new5(0, 0, 0)
    else
        QColor.new5(255, 255, 255);
    defer text_color.delete();

    var pixmap = QPixmap.new2(g_icon_size, g_icon_size);
    defer pixmap.delete();
    pixmap.fill1(bg);

    var painter = QPainter.new();
    defer painter.delete();
    _ = painter.begin(pixmap);
    defer _ = painter.end();

    painter.setRenderHint(1);
    painter.setPen(text_color);

    const border = @divTrunc(g_icon_size, 10);
    const radius = @as(f64, @floatFromInt(g_icon_size)) / 3.0;
    const iw = g_icon_size - 2 * border;
    painter.drawRoundedRect2(border, border, iw, iw, radius, radius);

    var font = QFont.new2("sans-serif");
    defer font.delete();
    font.setPixelSize(g_icon_size - @divTrunc(g_icon_size, 4));
    font.setBold(true);
    painter.setFont(font);

    var rect = QRect.new6(0, 0, g_icon_size, g_icon_size);
    defer rect.delete();

    var letter: [2]u8 = .{ first, 0 };
    painter.drawText6(rect, 132, letter[0..1]);

    return QIcon.new2(pixmap);
}

fn tryLoadIcon(app: de.DesktopApp) QIcon {
    if (app.icon) |icon_name| {
        if (icon_name.len > 0) {
            const icon = loadIcon(icon_name);
            if (!icon.isNull()) return icon;
            icon.delete();
        }
        const fallback = QIcon.fromTheme("application-x-executable");
        if (!fallback.isNull()) return fallback;
        fallback.delete();
    }
    return makeFallbackIcon(app.name);
}

fn tryLoadPluginIcon(icon_name: []const u8) QIcon {
    if (icon_name.len > 0) {
        const icon = loadIcon(icon_name);
        if (!icon.isNull()) return icon;
        icon.delete();
    }
    const fallback = QIcon.fromTheme("application-x-executable");
    if (!fallback.isNull()) return fallback;
    fallback.delete();
    return makeFallbackIcon("pl");
}

pub const ListItem = de.ListItem;

const DataSource = union(enum) {
    desktop_apps: []const de.DesktopApp,
    items: []const ListItem,
};

pub const IndexEntry = union(enum) {
    item: usize,
    plugin: usize,
    window: usize,
    window_message,
};

fn freePluginResults(allocator: std.mem.Allocator, results: *std.ArrayList(plugins.PluginResult)) void {
    for (results.items) |*plugin_result| plugin_result.deinit(allocator);
    results.clearRetainingCapacity();
}

var g_list: ?*List = null;
var g_painting_row: ?i32 = null;

// DecorationRole is also requested during layout. Only a real delegate paint
// may resolve an uncached icon; layout receives a cheap, same-sized placeholder.
fn onPaintItem(delegate: qt.QStyledItemDelegate, painter: QPainter, option: qt.QStyleOptionViewItem, index: QModelIndex) callconv(.c) void {
    const previous = g_painting_row;
    g_painting_row = index.row();
    defer g_painting_row = previous;
    delegate.superPaint(painter, option, index);
}

fn onListPaint(view: QListView, event: qt.QPaintEvent) callconv(.c) void {
    view.superPaintEvent(event);
    if (g_list) |list| {
        if (list.after_first_paint) |callback| {
            list.after_first_paint = null;
            callback();
        }
    }
}
var g_on_item_focused: ?*const fn (item_index: usize, actions: []const ListItemAction) void = null;
var g_current_item_actions: []const ListItemAction = &.{};

fn onDoubleClicked(_: QListView, _: QModelIndex) callconv(.c) void {
    if (g_list) |list| list.launchSelected();
}

fn onCurrentChanged(_: QListView, current: QModelIndex, _: QModelIndex) callconv(.c) void {
    const list = g_list orelse return;
    const row = current.row();
    if (row < 0) {
        g_current_item_actions = &.{};
        if (g_on_item_focused) |cb| cb(0, &.{});
        return;
    }
    const urow = @as(usize, @intCast(row));
    if (urow >= list.indices.items.len) return;

    const entry = list.indices.items[urow];
    switch (entry) {
        .item => |item_idx| {
            const items = switch (list.source) {
                .items => |is| is,
                .desktop_apps => {
                    g_current_item_actions = &.{};
                    if (g_on_item_focused) |cb| cb(item_idx, &.{});
                    return;
                },
            };
            g_current_item_actions = items[item_idx].actions;
            if (g_on_item_focused) |cb| cb(item_idx, items[item_idx].actions);
        },
        .plugin => |i| {
            g_current_item_actions = list.plugin_results.items[i].actions.items;
            if (g_on_item_focused) |cb| cb(0, g_current_item_actions);
        },
        .window, .window_message => {
            g_current_item_actions = &.{};
            if (g_on_item_focused) |cb| cb(0, &.{});
        },
    }
}

fn onRowCount(_: QAbstractListModel, _: QModelIndex) callconv(.c) i32 {
    const list = g_list orelse return 0;
    return @intCast(list.indices.items.len);
}

fn onData(
    _: QAbstractListModel,
    index: QModelIndex,
    role: i32,
) callconv(.c) QVariant {
    const list = g_list orelse return QVariant.new();
    const row = index.row();
    const indices = list.indices.items;
    if (row < 0 or @as(usize, @intCast(row)) >= indices.len)
        return QVariant.new();

    const entry = indices[@as(usize, @intCast(row))];
    const icon_start = if (role == 1) benchmark.iconStarted() else 0;
    defer benchmark.iconFinished(icon_start);

    if (role == 1) {
        if (g_no_icons) return QVariant.new();
        const cache = switch (entry) {
            .item => &list.item_icons,
            .plugin => &list.plugin_icons,
            .window, .window_message => &list.window_icons,
        };
        const key = switch (entry) {
            .item => |i| i,
            .plugin => |i| i,
            .window => |i| i,
            .window_message => std.math.maxInt(usize),
        };
        if (cache.get(key)) |icon| return icon.toQVariant();
        if (g_painting_row == null or g_painting_row.? != row)
            return list.placeholder_icon.toQVariant();
        const icon = switch (entry) {
            .item => |i| switch (list.source) {
                .desktop_apps => |apps| tryLoadIcon(apps[i]),
                .items => |items| loadItemIcon(items[i]),
            },
            .plugin => |i| tryLoadPluginIcon(list.plugin_results.items[i].icon),
            .window => |i| tryLoadPluginIcon(list.window_search.snapshot.windows.items[i].icon),
            .window_message => tryLoadPluginIcon("dialog-information"),
        };
        cache.put(list.allocator, key, icon) catch {
            defer icon.delete();
            return icon.toQVariant();
        };
        return icon.toQVariant();
    }

    switch (entry) {
        .item => |idx| {
            if (role == 0) {
                const name = switch (list.source) {
                    .desktop_apps => |apps| apps[idx].name,
                    .items => |items| items[idx].name,
                };
                return QVariant.new24(name);
            }
        },
        .plugin => |plugin_idx| {
            const plugin_result = &list.plugin_results.items[plugin_idx];
            if (role == 0) return QVariant.new24(plugin_result.title);
        },
        .window => |i| {
            if (role == 0) return QVariant.new24(list.window_search.snapshot.windows.items[i].title);
        },
        .window_message => {
            if (role == 0) return QVariant.new24(list.window_search.message orelse "Window switcher unavailable");
        },
    }

    return QVariant.new();
}

const FreqSortContext = struct {
    store: *freq.FrequencyStore,
    source: *const DataSource,
};

fn freqLessThan(ctx: FreqSortContext, a: IndexEntry, b: IndexEntry) bool {
    const item_a = switch (a) {
        .item => |i| i,
        .plugin, .window, .window_message => return false,
    };
    const item_b = switch (b) {
        .item => |i| i,
        .plugin, .window, .window_message => return true,
    };
    const key_a = switch (ctx.source.*) {
        .desktop_apps => |apps| apps[item_a].name,
        .items => |items| items[item_a].name,
    };
    const key_b = switch (ctx.source.*) {
        .desktop_apps => |apps| apps[item_b].name,
        .items => |items| items[item_b].name,
    };
    const score_a = ctx.store.getScore(key_a);
    const score_b = ctx.store.getScore(key_b);
    if (score_a != score_b) return score_a > score_b;
    const cmp = std.ascii.orderIgnoreCase(key_a, key_b);
    if (cmp != .eq) return cmp == .lt;
    return item_a < item_b;
}

pub const List = struct {
    allocator: std.mem.Allocator,
    view: QListView,
    model: QAbstractListModel,
    source: DataSource,
    indices: std.ArrayList(IndexEntry),
    plugin_results: std.ArrayList(plugins.PluginResult),
    plugin_manager: ?*plugins.PluginManager,
    frequency_store: ?*freq.FrequencyStore,
    run_mode: bool = false,
    window_search: window_search.Search = .{},
    window_icons: std.AutoHashMapUnmanaged(usize, QIcon) = .empty,
    item_icons: std.AutoHashMapUnmanaged(usize, QIcon) = .empty,
    plugin_icons: std.AutoHashMapUnmanaged(usize, QIcon) = .empty,
    placeholder_icon: QIcon,
    after_first_paint: ?*const fn () void = null,
    on_query_requested: ?*const fn ([]const u8) void = null,
    revision: usize = 0,

    pub fn init(allocator: std.mem.Allocator, apps: []const de.DesktopApp, icon_size: i32, plugin_manager: ?*plugins.PluginManager) List {
        g_icon_size = icon_size;
        const result = initInternal(allocator, .{ .desktop_apps = apps }, icon_size, plugin_manager);
        return result;
    }

    pub fn fromItems(allocator: std.mem.Allocator, items: []const ListItem, icon_size: i32) List {
        g_icon_size = icon_size;
        const result = initInternal(allocator, .{ .items = items }, icon_size, null);
        return result;
    }

    fn initInternal(allocator: std.mem.Allocator, source: DataSource, icon_size: i32, plugin_manager: ?*plugins.PluginManager) List {
        g_icon_size = icon_size;

        var model = QAbstractListModel.new();
        model.onRowCount(onRowCount);
        model.onData(onData);

        var view = QListView.new2();
        view.setAutoFillBackground(false);
        view.setAlternatingRowColors(false);
        view.setObjectName("appList");
        var viewport = view.viewport();
        viewport.setAutoFillBackground(false);
        var icon_sz = QSize.new4(icon_size, icon_size);
        defer icon_sz.delete();
        view.setIconSize(icon_sz);
        view.setVerticalScrollMode(qt.qabstractitemview_enums.ScrollMode.ScrollPerItem);
        var delegate = qt.QStyledItemDelegate.new2(view);
        delegate.onPaint(onPaintItem);
        view.setItemDelegate(delegate);
        view.onPaintEvent(onListPaint);
        var placeholder = QPixmap.new2(icon_size, icon_size);
        defer placeholder.delete();
        const transparent = QColor.new15(0, 0, 0, 0);
        defer transparent.delete();
        placeholder.fill1(transparent);

        const result = List{
            .allocator = allocator,
            .view = view,
            .model = model,
            .source = source,
            .indices = std.ArrayList(IndexEntry).empty,
            .plugin_results = std.ArrayList(plugins.PluginResult).empty,
            .plugin_manager = plugin_manager,
            .frequency_store = null,
            .placeholder_icon = QIcon.new2(placeholder),
        };
        view.setModel(model);
        view.onCurrentChanged(onCurrentChanged);
        view.onDoubleClicked(onDoubleClicked);

        return result;
    }

    pub fn setOnItemFocused(callback: ?*const fn (item_index: usize, actions: []const ListItemAction) void) void {
        g_on_item_focused = callback;
    }

    pub fn adoptGList(self: *List) void {
        g_list = self;
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
        g_list = self;
        self.revision +%= 1;
        g_current_item_actions = &.{};
        self.model.beginResetModel();
        defer self.model.endResetModel();
        self.clearIconMap(&self.plugin_icons);
        self.clearIconMap(&self.window_icons);
        const work = benchmark.workStart();
        defer benchmark.workEnd(.list_prepare, work);
        freePluginResults(self.allocator, &self.plugin_results);
        self.indices.clearRetainingCapacity();

        if (self.run_mode) {
            return;
        }

        const windows_active = self.window_search.query(self.allocator, text) catch blk: {
            self.window_search.message = "Unable to prepare window results";
            break :blk true;
        };
        if (windows_active) {
            self.appendWindowRows();
            return;
        }

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

        const plugin_count = if (self.plugin_manager != null and text.len > 0) blk: {
            const pm = self.plugin_manager.?;
            pm.queryAll(text, &self.plugin_results);
            for (0..self.plugin_results.items.len) |plugin_index| {
                self.indices.append(self.allocator, IndexEntry{ .plugin = plugin_index }) catch |err| log.info("OOM in setFilter: {}", .{err});
            }
            break :blk self.plugin_results.items.len;
        } else 0;

        if (self.frequency_store) |store| {
            const item_count = self.indices.items.len - plugin_count;
            if (item_count > 1) {
                const ctx = FreqSortContext{ .store = store, .source = &self.source };
                std.sort.insertion(IndexEntry, self.indices.items[0..item_count], ctx, freqLessThan);
            }
        }
    }

    fn clearIconMap(self: *List, cache: *std.AutoHashMapUnmanaged(usize, QIcon)) void {
        _ = self;
        var it = cache.valueIterator();
        while (it.next()) |icon| icon.delete();
        cache.clearRetainingCapacity();
    }

    fn appendWindowRows(self: *List) void {
        if (self.window_search.message != null) self.indices.append(self.allocator, .window_message) catch {};
        for (self.window_search.matches.items) |i| self.indices.append(self.allocator, .{ .window = i }) catch {};
    }

    pub fn invalidateIcons(self: *List) void {
        self.clearIconMap(&self.item_icons);
        self.clearIconMap(&self.plugin_icons);
        self.clearIconMap(&self.window_icons);
    }

    pub fn invalidIndex() QModelIndex {
        return QModelIndex.new3();
    }

    pub fn selectFirst(self: *List) void {
        if (self.indices.items.len > 0) {
            self.selectRow(0);
        }
    }

    pub fn selectRow(self: *List, row: i32) void {
        var invalid = List.invalidIndex();
        defer invalid.delete();
        var idx = self.model.index(row, 0, invalid);
        defer idx.delete();
        self.view.setCurrentIndex(idx);
        self.view.scrollTo(idx, qt.qabstractitemview_enums.ScrollHint.EnsureVisible);
    }

    fn freeArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
        for (argv) |arg| allocator.free(arg);
        allocator.free(argv);
    }

    pub fn launchSelected(self: *List) void {
        if (!self.view.currentIndex().isValid()) {
            self.selectFirst();
        }

        var idx = self.view.currentIndex();
        defer idx.delete();
        if (!idx.isValid()) return;

        const row = @as(usize, @intCast(idx.row()));
        if (row >= self.indices.items.len) return;

        switch (self.indices.items[row]) {
            .item => |item_idx| {
                if (self.frequency_store) |store| {
                    store.increment(self.sourceName(item_idx));
                }
                switch (self.source) {
                    .desktop_apps => |apps| {
                        const app = &apps[item_idx];
                        const exec = app.exec orelse "";
                        if (exec.len > 0) {
                            const expanded = de.DesktopEntry.expandExecString(exec, app, self.allocator) catch "";
                            if (expanded.len > 0) {
                                defer self.allocator.free(expanded);
                                const argv = utils.tokenizeCommandLine(self.allocator, expanded) catch null;
                                if (argv) |argv_slice| {
                                    defer freeArgv(self.allocator, argv_slice);
                                    utils.executeArgv(self.allocator, argv_slice) catch |err| {
                                        utils.log.info("failed to launch '{s}': {}", .{ app.name, err });
                                    };
                                }
                            }
                        }
                    },
                    .items => |items| {
                        const item = &items[item_idx];
                        if (item.desktop_app_idx != null) {
                            // Desktop apps and their actions are pre-expanded
                            // by desktop_loader and launched via execve, never
                            // through a shell.
                            if (item.cmd.len > 0) {
                                const argv = utils.tokenizeCommandLine(self.allocator, item.cmd) catch null;
                                if (argv) |argv_slice| {
                                    defer freeArgv(self.allocator, argv_slice);
                                    utils.executeArgv(self.allocator, argv_slice) catch |err| {
                                        utils.log.info("failed to launch '{s}': {}", .{ item.name, err });
                                    };
                                }
                            }
                        } else {
                            // Plain menu entries (--menu=...) are raw shell
                            // command lines by design.
                            utils.execute(item.cmd, self.allocator) catch {};
                        }
                    },
                }
            },
            .plugin => |plugin_result_index| {
                const plugin_result = &self.plugin_results.items[plugin_result_index];
                if (self.plugin_manager) |plugin_manager| {
                    plugin_manager.handleSelect(plugin_result);
                    if (self.applyPluginQuery(plugin_manager)) return;
                    if (plugin_result.result_type == .NoReturn and !plugin_manager.close_requested) return;
                }
            },
            .window => |i| {
                if (!self.window_search.select(self.allocator, i)) {
                    self.model.beginResetModel();
                    self.indices.clearRetainingCapacity();
                    self.appendWindowRows();
                    self.model.endResetModel();
                    return;
                }
            },
            .window_message => return,
        }
        animation.animateFadeOutAndQuit();
    }

    pub fn launchRunCommand(self: *List, command: []const u8) void {
        const trimmed = std.mem.trim(u8, command, " \t\r\n");
        if (trimmed.len == 0) return;
        utils.execute(trimmed, self.allocator) catch |err| {
            log.info("Run command failed: {}", .{err});
            return;
        };
        animation.animateFadeOutAndQuit();
    }

    fn applyPluginQuery(self: *List, manager: *plugins.PluginManager) bool {
        const query = manager.pending_query orelse return false;
        manager.pending_query = null;
        defer manager.allocator.free(query);
        if (self.on_query_requested) |callback| callback(query) else self.setFilter(query);
        return true;
    }

    pub fn selectedEntry(self: *List) ?IndexEntry {
        const index = self.view.currentIndex();
        defer index.delete();
        if (!index.isValid() or index.row() < 0) return null;
        const row: usize = @intCast(index.row());
        return if (row < self.indices.items.len) self.indices.items[row] else null;
    }

    pub fn selectedName(self: *List) []const u8 {
        return switch (self.selectedEntry() orelse return "") {
            .item => |i| self.sourceName(i),
            .plugin => |i| self.plugin_results.items[i].title,
            .window => |i| self.window_search.snapshot.windows.items[i].title,
            .window_message => self.window_search.message orelse "",
        };
    }

    pub fn selectedCommand(self: *List) ?[]const u8 {
        return switch (self.selectedEntry() orelse return null) {
            .item => |i| switch (self.source) {
                .items => |items| items[i].cmd,
                .desktop_apps => |apps| apps[i].exec,
            },
            .plugin => |i| self.plugin_results.items[i].exec,
            else => null,
        };
    }

    pub fn launchAction(self: *List, index: usize) void {
        if (index >= g_current_item_actions.len) return;
        const action = g_current_item_actions[index];
        if (action.id) |id| {
            const entry = self.selectedEntry() orelse return;
            if (entry != .plugin) return;
            const manager = self.plugin_manager orelse return;
            manager.handleAction(&self.plugin_results.items[entry.plugin], id);
            if (self.applyPluginQuery(manager)) return;
            if (manager.close_requested) animation.animateFadeOutAndQuit();
            return;
        }
        if (action.exec.len == 0) return;
        const argv = utils.tokenizeCommandLine(self.allocator, action.exec) catch return;
        defer freeArgv(self.allocator, argv);
        utils.executeArgv(self.allocator, argv) catch |err| {
            log.info("failed to launch action: {}", .{err});
            return;
        };
        animation.animateFadeOutAndQuit();
    }

    pub fn setNoIcons(v: bool) void {
        g_no_icons = v;
    }

    pub fn deinit(self: *List) void {
        g_current_item_actions = &.{};
        g_list = null;
        self.invalidateIcons();
        self.item_icons.deinit(self.allocator);
        self.plugin_icons.deinit(self.allocator);
        self.window_icons.deinit(self.allocator);
        self.window_search.deinit(self.allocator);
        self.placeholder_icon.delete();
        freePluginResults(self.allocator, &self.plugin_results);
        self.plugin_results.deinit(self.allocator);
        self.model.delete();
        self.indices.deinit(self.allocator);
    }
};
