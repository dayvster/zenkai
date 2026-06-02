const std = @import("std");
const qt = @import("libqt6zig");
const de = @import("desktopapp");
const utils = @import("utils");

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

var g_icon_size: i32 = 32;

fn loadIcon(icon_name: []const u8) QIcon {
    if (icon_name.len > 0 and icon_name[0] == '/') {
        return QIcon.New4(icon_name);
    }
    return QIcon.FromTheme(icon_name);
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

    var font = QFont.New2("sans-serif");
    defer font.Delete();
    font.SetPixelSize(g_icon_size - 4);
    font.SetBold(true);
    painter.SetFont(font);

    var rect = QRect.New6(0, 0, g_icon_size, g_icon_size);
    defer rect.Delete();

    var letter: [2]u8 = .{ first, 0 };
    painter.DrawText6(rect, 132, letter[0..1]);

    return QIcon.New2(pixmap);
}

var g_apps: []const de.DesktopApp = undefined;
var g_indices: []const usize = &[_]usize{};

fn onRowCount(_: QAbstractListModel, _: QModelIndex) callconv(.c) i32 {
    return @intCast(g_indices.len);
}

fn onData(_: QAbstractListModel, index: QModelIndex, role: i32) callconv(.c) QVariant {
    const row = index.Row();
    if (row < 0 or @as(usize, @intCast(row)) >= g_indices.len)
        return QVariant.New();

    const app = g_apps[g_indices[@as(usize, @intCast(row))]];

    if (role == 0) {
        return QVariant.New24(app.name);
    }
    if (role == 1) {
        var icon: QIcon = undefined;
        if (app.icon) |icon_name| {
            if (icon_name.len > 0) {
                icon = loadIcon(icon_name);
                if (icon.IsNull()) {
                    icon.Delete();
                    icon = makeFallbackIcon(app.name);
                }
            } else {
                icon = makeFallbackIcon(app.name);
            }
        } else {
            icon = makeFallbackIcon(app.name);
        }
        defer icon.Delete();
        return icon.ToQVariant();
    }

    return QVariant.New();
}

pub const List = struct {
    allocator: std.mem.Allocator,
    view: QListView,
    model: QAbstractListModel,
    apps: []const de.DesktopApp,
    indices: std.ArrayList(usize),

    pub fn init(allocator: std.mem.Allocator, apps: []const de.DesktopApp, icon_size: i32) List {
        g_icon_size = icon_size;

        var model = QAbstractListModel.New();
        model.OnRowCount(onRowCount);
        model.OnData(onData);

        g_apps = apps;

        var view = QListView.New2();
        view.SetIconSize(QSize.New4(icon_size, icon_size));
        view.SetModel(model);

        return .{
            .allocator = allocator,
            .view = view,
            .model = model,
            .apps = apps,
            .indices = std.ArrayList(usize).empty,
        };
    }

    pub fn setFilter(self: *List, text: []const u8) void {
        self.indices.clearRetainingCapacity();

        if (text.len == 0) {
            for (0..self.apps.len) |i|
                self.indices.append(self.allocator, i) catch {};
        } else {
            var lower_text_buf: [256]u8 = undefined;
            const lower_text = if (text.len <= lower_text_buf.len) blk: {
                for (text, 0..) |c, i| lower_text_buf[i] = std.ascii.toLower(c);
                break :blk lower_text_buf[0..text.len];
            } else text;

            const max_distance: usize = if (text.len < 3) 0 else 3;

            for (self.apps, 0..) |app, i| {
                var lower_name_buf: [256]u8 = undefined;
                var matches = false;

                if (app.name.len <= lower_name_buf.len) {
                    for (app.name, 0..) |c, j| lower_name_buf[j] = std.ascii.toLower(c);
                    const lower_name = lower_name_buf[0..app.name.len];

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
                    self.indices.append(self.allocator, i) catch {};
                }
            }
        }

        self.model.BeginResetModel();
        g_indices = self.indices.items;
        self.model.EndResetModel();

        if (self.indices.items.len > 0) {
            var invalid = QModelIndex.New3();
            var idx = self.model.Index(0, 0, invalid);
            self.view.SetCurrentIndex(idx);
            invalid.Delete();
            idx.Delete();
        }
    }

    pub fn getExecForRow(self: *List, row: usize) []const u8 {
        return self.apps[self.indices.items[row]].exec orelse "";
    }

    pub fn deinit(self: *List) void {
        self.indices.deinit(self.allocator);
    }
};
