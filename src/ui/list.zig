const std = @import("std");
const qt = @import("libqt6zig");
const de = @import("desktopapp");
const utils = @import("../utils/utils.zig");

const QListWidget = qt.QListWidget;
const QListWidgetItem = qt.QListWidgetItem;
const QIcon = qt.QIcon;
const QSize = qt.QSize;
const QImage = qt.QImage;
const QPixmap = qt.QPixmap;

const icon_size: i32 = 16;

fn loadIcon(icon_name: []const u8) QIcon {
    if (icon_name.len > 0 and icon_name[0] == '/') {
        var image = QImage.New9(icon_name);
        defer image.Delete();
        var scaled = image.Scaled(icon_size, icon_size);
        defer scaled.Delete();
        var pixmap = QPixmap.FromImage(scaled);
        defer pixmap.Delete();
        return QIcon.New2(pixmap);
    }
    return QIcon.FromTheme(icon_name);
}

pub const List = struct {
    allocator: std.mem.Allocator,
    widget: QListWidget,
    lower_names: std.ArrayList([]const u8),
    exec_cmds: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, apps: []const de.DesktopApp) List {
        const widget = QListWidget.New2();
        widget.SetSortingEnabled(false);
        widget.SetIconSize(QSize.New4(icon_size, icon_size));

        var lower_names = std.ArrayList([]const u8).empty;
        var exec_cmds = std.ArrayList([]const u8).empty;

        for (apps, 0..) |app, idx| {
            widget.AddItem(app.name);

            if (app.icon) |icon_name| {
                const icon = loadIcon(icon_name);

                var item = widget.Item(@intCast(idx));
                item.SetIcon(icon);
                icon.Delete();
            }

            exec_cmds.append(allocator, allocator.dupe(u8, app.exec) catch "") catch {};

            var buf: [256]u8 = undefined;
            if (app.name.len <= buf.len) {
                for (app.name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
                lower_names.append(allocator, allocator.dupe(u8, buf[0..app.name.len]) catch "") catch {};
            } else {
                lower_names.append(allocator, "") catch {};
            }
        }

        return .{
            .allocator = allocator,
            .widget = widget,
            .lower_names = lower_names,
            .exec_cmds = exec_cmds,
        };
    }

    pub fn setFilter(self: *List, text: []const u8) void {
        var lower_text_buf: [256]u8 = undefined;
        const lower_text = if (text.len <= lower_text_buf.len) blk: {
            for (text, 0..) |c, i| lower_text_buf[i] = std.ascii.toLower(c);
            break :blk lower_text_buf[0..text.len];
        } else text;

        const max_distance: usize = if (text.len < 3) 0 else 3;

        for (self.lower_names.items, 0..) |n, i| {
            const row: i32 = @intCast(i);

            if (std.mem.indexOf(u8, n, lower_text) != null) {
                self.widget.Item(row).SetHidden(false);
                continue;
            }

            if (max_distance > 0) {
                const dist = utils.demerauLevenshteinDistance(self.allocator, lower_text, n, max_distance) catch max_distance;
                if (dist < max_distance) {
                    self.widget.Item(row).SetHidden(false);
                    continue;
                }
            }

            self.widget.Item(row).SetHidden(true);
        }

        self.selectFirstVisible();
    }

    fn selectFirstVisible(self: *List) void {
        const count = self.widget.Count();
        var row: i32 = 0;
        while (row < count) : (row += 1) {
            if (!self.widget.Item(row).IsHidden()) {
                self.widget.SetCurrentRow(row);
                return;
            }
        }
        self.widget.SetCurrentRow(-1);
    }

    pub fn deinit(self: *List) void {
        for (self.lower_names.items) |n| self.allocator.free(n);
        self.lower_names.deinit(self.allocator);
        for (self.exec_cmds.items) |c| self.allocator.free(c);
        self.exec_cmds.deinit(self.allocator);
    }
};
