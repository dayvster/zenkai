const std = @import("std");
const qt = @import("libqt6zig");
const applist = @import("list.zig");
const de = @import("desktopapp");
const desktop_loader = @import("../core/desktop_loader.zig");
const utils = @import("utils");
const lang = @import("lang");

const QAction = qt.QAction;
const QMessageBox = qt.QMessageBox;
const QPixmap = qt.QPixmap;
const QIcon = qt.QIcon;

var g_list: *applist.List = undefined;
var g_parent: qt.QWidget = undefined;

pub fn setup(list: *applist.List, parent: qt.QWidget) void {
    g_list = list;
    g_parent = parent;
}

fn currentApp() ?*const de.DesktopApp {
    var idx = g_list.view.currentIndex();
    defer idx.delete();
    if (!idx.isValid()) return null;
    const row = @as(usize, @intCast(idx.row()));
    if (row >= g_list.indices.items.len) return null;
    const entry = g_list.indices.items[row];
    const item_idx = switch (entry) {
        .item => |i| i,
        .plugin => return null,
    };
    const da_idx = switch (g_list.source) {
        .desktop_apps => |apps| {
            return &apps[item_idx];
        },
        .items => |items| items[item_idx].desktop_app_idx orelse return null,
    };
    const apps = desktop_loader.getDesktopApps();
    if (da_idx < apps.len) return &apps[da_idx];
    return null;
}

fn loadAppIcon(icon_name: ?[]const u8) QIcon {
    if (icon_name) |name| {
        if (name.len > 0) {
            const icon = if (name[0] == '/') QIcon.new4(name) else QIcon.fromTheme(name);
            if (!icon.isNull()) return icon;
            icon.delete();
        }
    }
    const fallback = QIcon.fromTheme("dialog-information");
    if (!fallback.isNull()) return fallback;
    fallback.delete();
    return QIcon.new();
}

fn makeInfoIcon(icon_name: ?[]const u8) QPixmap {
    var app_icon = loadAppIcon(icon_name);
    defer app_icon.delete();
    if (!app_icon.isNull()) {
        return app_icon.pixmap2(64, 64);
    }
    return QPixmap.new2(64, 64);
}

const Html = struct {
    buf: std.ArrayList(u8),
    gpa: std.mem.Allocator,

    fn append(self: *Html, s: []const u8) void {
        self.buf.appendSlice(self.gpa, s) catch {};
    }

    fn field(self: *Html, label: []const u8, value: []const u8) void {
        const ev = utils.esc(self.gpa, value) catch return;
        defer self.gpa.free(ev);
        self.append("<tr><td style='padding-right: 20px; white-space: nowrap; vertical-align: top; padding-bottom: 3px; font-weight: 600; font-size: 12px;'>");
        self.append(label);
        self.append("</td><td style='padding-bottom: 3px;'>");
        self.append(ev);
        self.append("</td></tr>");
    }

    fn optField(self: *Html, label: []const u8, value: ?[]const u8) void {
        if (value) |v| if (v.len > 0) self.field(label, v);
    }

    fn boolField(self: *Html, label: []const u8, value: bool) void {
        self.field(label, if (value) lang.get().checkmark else lang.get().em_dash);
    }

    fn nullableBoolField(self: *Html, label: []const u8, value: ?bool) void {
        if (value) |v| self.boolField(label, v);
    }

    fn arrField(self: *Html, label: []const u8, value: [][]const u8) void {
        if (value.len == 0) return;
        var items: std.ArrayList(u8) = .empty;
        defer items.deinit(self.gpa);
        for (value, 0..) |item, i| {
            if (i > 0) items.appendSlice(self.gpa, ", ") catch return;
            const es = utils.esc(self.gpa, item) catch return;
            defer self.gpa.free(es);
            items.appendSlice(self.gpa, es) catch return;
        }
        self.field(label, items.items);
    }

    fn rowBreak(self: *Html) void {
        self.append("<tr><td colspan='2' style='padding-top: 8px;'><hr></td></tr>");
    }

    fn rowHeader(self: *Html, label: []const u8) void {
        self.append("<tr><td colspan='2' style='padding-top: 2px; padding-bottom: 6px; font-size: 12px; font-weight: 700; letter-spacing: 0.8px; text-transform: uppercase;'>");
        self.append(label);
        self.append("</td></tr>");
    }
};

pub fn onInfo(_: QAction) callconv(.c) void {
    showInfoPanel();
}

pub fn showInfoPanel() void {
    const app = currentApp() orelse return;

    var html = Html{ .buf = .empty, .gpa = g_list.allocator };
    defer html.buf.deinit(html.gpa);

    {
        const name_esc = utils.esc(html.gpa, app.name) catch return;
        defer html.gpa.free(name_esc);
        html.append("<html><body style='padding: 12px; margin: 0;'><h2 style='margin: 0 0 14px 0; padding: 0; font-size: 20px; font-weight: 700; letter-spacing: 0.3px;'>");
        html.append(name_esc);
        html.append("</h2><table style='border-collapse: collapse; width: 100%;'>");
    }

    html.field(lang.get().info_type, @tagName(app.type));
    html.field(lang.get().info_name, app.name);
    html.optField(lang.get().info_generic_name, app.generic_name);
    html.optField(lang.get().info_comment, app.comment);
    html.optField(lang.get().info_version, app.version);

    html.rowBreak();
    html.rowHeader(lang.get().info_execution);

    html.optField(lang.get().info_exec, app.exec);
    html.optField(lang.get().info_try_exec, app.try_exec);
    html.optField(lang.get().info_working_dir, app.path);
    html.boolField(lang.get().info_run_in_terminal, app.terminal);

    html.rowBreak();
    html.rowHeader(lang.get().info_desktop);

    html.optField(lang.get().info_file_path, app.file_path);
    html.optField(lang.get().info_icon, app.icon);
    html.optField(lang.get().info_startup_wm_class, app.startup_wm_class);
    html.optField(lang.get().info_url, app.url);

    html.rowBreak();
    html.rowHeader(lang.get().info_flags);

    html.boolField(lang.get().info_no_display, app.no_display);
    html.boolField(lang.get().info_hidden, app.hidden);
    html.boolField(lang.get().info_dbus_activatable, app.dbus_activatable);
    html.nullableBoolField(lang.get().info_startup_notify, app.startup_notify);
    html.boolField(lang.get().info_prefers_non_gpu, app.prefers_non_default_gpu);
    html.boolField(lang.get().info_single_window, app.single_main_window);

    html.rowBreak();
    html.rowHeader(lang.get().info_categories);

    html.arrField(lang.get().info_categories, app.categories);
    html.arrField(lang.get().info_keywords, app.keywords);
    html.arrField(lang.get().info_mime_types, app.mime_type);
    html.arrField(lang.get().info_only_show_in, app.only_show_in);
    html.arrField(lang.get().info_not_show_in, app.not_show_in);

    html.append("</table></body></html>");

    const html_str = html.buf.toOwnedSlice(html.gpa) catch return;
    defer html.gpa.free(html_str);

    var icon_pix = makeInfoIcon(app.icon);
    defer icon_pix.delete();

    var mb = QMessageBox.new6(
        qt.qmessagebox_enums.Icon.Information,
        app.name,
        html_str,
        qt.qmessagebox_enums.StandardButton.Ok,
        g_parent,
    );
    defer mb.delete();
    mb.setIconPixmap(icon_pix);
    mb.setTextFormat(qt.qnamespace_enums.TextFormat.RichText);
    mb.setMinimumSize2(440, 350);
    _ = mb.exec();
}
