const std = @import("std");
const qt = @import("libqt6zig");
const theme = @import("../theme/theme.zig");
const applist = @import("list.zig");
const de = @import("desktopapp");
const utils = @import("utils");

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
    var idx = g_list.view.CurrentIndex();
    defer idx.Delete();
    if (!idx.IsValid()) return null;
    const row = @as(usize, @intCast(idx.Row()));
    if (row >= g_list.indices.items.len) return null;
    return switch (g_list.source) {
        .desktop_apps => |apps| &apps[g_list.indices.items[row]],
        .items => null,
    };
}

fn loadAppIcon(icon_name: ?[]const u8) QIcon {
    if (icon_name) |name| {
        if (name.len > 0) {
            const icon = if (name[0] == '/') QIcon.New4(name) else QIcon.FromTheme(name);
            if (!icon.IsNull()) return icon;
            icon.Delete();
        }
    }
    const fallback = QIcon.FromTheme("dialog-information");
    if (!fallback.IsNull()) return fallback;
    fallback.Delete();
    return QIcon.New();
}

fn makeInfoIcon(icon_name: ?[]const u8) QPixmap {
    var app_icon = loadAppIcon(icon_name);
    defer app_icon.Delete();
    if (!app_icon.IsNull()) {
        return app_icon.Pixmap2(64, 64);
    }
    return QPixmap.New2(64, 64);
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
        self.append("<tr><td style='color: ");
        self.append(theme.current.muted);
        self.append("; padding-right: 20px; white-space: nowrap; vertical-align: top; padding-bottom: 3px; font-weight: 600; font-size: 12px;'>");
        self.append(label);
        self.append("</td><td style='padding-bottom: 3px;'>");
        self.append(ev);
        self.append("</td></tr>");
    }

    fn optField(self: *Html, label: []const u8, value: ?[]const u8) void {
        if (value) |v| if (v.len > 0) self.field(label, v);
    }

    fn boolField(self: *Html, label: []const u8, value: bool) void {
        self.field(label, if (value) "✓" else "—");
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
        self.append("<tr><td colspan='2' style='padding-top: 8px;'><hr style='border: none; border-top: 1px solid ");
        self.append(theme.current.border);
        self.append(";'></td></tr>");
    }

    fn rowHeader(self: *Html, label: []const u8) void {
        self.append("<tr><td colspan='2' style='padding-top: 2px; padding-bottom: 6px; color: ");
        self.append(theme.current.accent);
        self.append("; font-size: 12px; font-weight: 700; letter-spacing: 0.8px; text-transform: uppercase;'>");
        self.append(label);
        self.append("</td></tr>");
    }
};

pub fn onInfo(_: QAction) callconv(.c) void {
    const app = currentApp() orelse return;

    var html = Html{ .buf = .empty, .gpa = g_list.allocator };
    defer html.buf.deinit(html.gpa);

    {
        const name_esc = utils.esc(html.gpa, app.name) catch return;
        defer html.gpa.free(name_esc);
        html.append("<html><body style='font-family: sans-serif; font-size: 13px; color: ");
        html.append(theme.current.text);
        html.append("; background: ");
        html.append(theme.current.bg);
        html.append("; padding: 12px; margin: 0;'><h2 style='margin: 0 0 14px 0; padding: 0; color: ");
        html.append(theme.current.accent);
        html.append("; font-size: 20px; font-weight: 700; letter-spacing: 0.3px;'>");
        html.append(name_esc);
        html.append("</h2><table style='border-collapse: collapse; width: 100%;'>");
    }

    html.field("Type", @tagName(app.type));
    html.field("Name", app.name);
    html.optField("Generic Name", app.generic_name);
    html.optField("Comment", app.comment);
    html.optField("Version", app.version);

    html.rowBreak();
    html.rowHeader("Execution");

    html.optField("Exec", app.exec);
    html.optField("Try Exec", app.try_exec);
    html.optField("Working Dir", app.path);
    html.boolField("Run in Terminal", app.terminal);

    html.rowBreak();
    html.rowHeader("Desktop");

    html.optField("File Path", app.file_path);
    html.optField("Icon", app.icon);
    html.optField("Startup WM Class", app.startup_wm_class);
    html.optField("URL", app.url);

    html.rowBreak();
    html.rowHeader("Flags");

    html.boolField("No Display", app.no_display);
    html.boolField("Hidden", app.hidden);
    html.boolField("D-Bus Activatable", app.dbus_activatable);
    html.nullableBoolField("Startup Notify", app.startup_notify);
    html.boolField("Prefers Non-GPU", app.prefers_non_default_gpu);
    html.boolField("Single Window", app.single_main_window);

    html.rowBreak();
    html.rowHeader("Categories");

    html.arrField("Categories", app.categories);
    html.arrField("Keywords", app.keywords);
    html.arrField("MIME Types", app.mime_type);
    html.arrField("Only Show In", app.only_show_in);
    html.arrField("Not Show In", app.not_show_in);

    html.append("</table></body></html>");

    const html_str = html.buf.toOwnedSlice(html.gpa) catch return;
    defer html.gpa.free(html_str);

    var icon_pix = makeInfoIcon(app.icon);
    defer icon_pix.Delete();

    var mb = QMessageBox.New6(
        qt.qmessagebox_enums.Icon.Information,
        app.name,
        html_str,
        qt.qmessagebox_enums.StandardButton.Ok,
        g_parent,
    );
    defer mb.Delete();
    mb.SetIconPixmap(icon_pix);
    mb.SetTextFormat(qt.qnamespace_enums.TextFormat.RichText);
    mb.SetMinimumSize2(440, 350);
    _ = mb.Exec();
}
