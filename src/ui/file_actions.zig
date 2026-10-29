const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const files = @import("plugins").files;
const utils = @import("utils");

pub var parent: ?qt.QWidget = null;
var busy = false;
pub fn isOpen() bool {
    return busy;
}

pub fn perform(a: std.mem.Allocator, action: []const u8, raw: []const u8) !?[]u8 {
    const host = parent orelse return error.ActionUnavailable;
    if (busy) return error.ActionUnavailable;
    busy = true;
    defer busy = false;
    const path = try files.absolute(a, raw);
    defer a.free(path);
    const info = qt.QFileInfo.new2(path);
    defer info.delete();
    if (!info.exists() and !info.isSymLink()) return error.FileNotFound;
    const container = std.fs.path.dirname(path) orelse path;
    if (std.mem.eql(u8, action, "reveal")) {
        try reveal(a, path);
        return try a.dupe(u8, path);
    }
    const rename = std.mem.eql(u8, action, "rename");
    const trash = std.mem.eql(u8, action, "trash");
    if ((rename or trash) and std.mem.eql(u8, container, path)) return error.ProtectedPath;
    if (trash) {
        const message = try std.fmt.allocPrint(a, "Move this item to the trash?\n\n{s}", .{path});
        defer a.free(message);
        const dialog = qt.QMessageBox.new(host);
        defer dialog.delete();
        dialog.setWindowTitle("Move to Trash");
        dialog.setTextFormat(qt.qnamespace_enums.TextFormat.PlainText);
        dialog.setText(message);
        const buttons = qt.qmessagebox_enums.StandardButton;
        dialog.setStandardButtons(buttons.Yes | buttons.Cancel);
        dialog.setDefaultButton2(buttons.Cancel);
        if (dialog.exec() != buttons.Yes) return null;
        const normalized = try a.dupe(u8, path);
        defer a.free(normalized);
        if (builtin.os.tag == .windows) std.mem.replaceScalar(u8, normalized, '\\', '/');
        if (!qt.QFile.moveToTrash2(normalized)) return error.TrashFailed;
        return try a.dupe(u8, container);
    }
    const folder = std.mem.eql(u8, action, "new_folder");
    if (!rename and !folder and !std.mem.eql(u8, action, "new_file")) return error.ActionUnavailable;
    const directory = if (info.isDir()) path else container;
    const title = if (rename) "Rename" else if (folder) "New Folder" else "New File";
    const caption = try std.fmt.allocPrint(a, "{s} - {s}", .{ title, if (rename) path else directory });
    defer a.free(caption);
    var accepted = false;
    const name = qt.QInputDialog.getText6(a, host, caption, "Name:", qt.qlineedit_enums.EchoMode.Normal, if (rename) std.fs.path.basename(path) else "", &accepted);
    defer a.free(name);
    if (!accepted) return null;
    return if (rename) try files.rename(a, path, name) else try files.create(a, directory, name, folder);
}

extern "shell32" fn SHParseDisplayName([*:0]const u16, ?*anyopaque, *?*anyopaque, u32, ?*u32) callconv(.winapi) i32;
extern "shell32" fn SHOpenFolderAndSelectItems(*const anyopaque, u32, ?*const anyopaque, u32) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;

fn reveal(a: std.mem.Allocator, path: []const u8) !void {
    if (comptime builtin.os.tag == .windows) {
        const initialized = CoInitializeEx(null, 2);
        defer if (initialized >= 0) CoUninitialize();
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        defer a.free(wide);
        var item: ?*anyopaque = null;
        if (SHParseDisplayName(wide, null, &item, 0, null) < 0 or item == null) return error.FileNotFound;
        defer CoTaskMemFree(item);
        if (SHOpenFolderAndSelectItems(item.?, 0, null, 0) < 0) return error.ActionUnavailable;
    } else if (comptime builtin.os.tag == .macos) {
        try utils.spawnTool("/usr/bin/open", &.{ "-R", path }, a);
    } else {
        const url = qt.QUrl.fromLocalFile(path);
        defer url.delete();
        const encoded = url.toEncoded(a);
        defer a.free(encoded);
        // dbus-send separates array elements with commas, even within one argv item.
        const escaped = try std.mem.replaceOwned(u8, a, encoded, ",", "%2C");
        defer a.free(escaped);
        const argument = try std.fmt.allocPrint(a, "array:string:{s}", .{escaped});
        defer a.free(argument);
        var output: [1024]u8 = undefined;
        const result = utils.runToolTimed("dbus-send", &.{ "--session", "--print-reply", "--reply-timeout=1000", "--dest=org.freedesktop.FileManager1", "/org/freedesktop/FileManager1", "org.freedesktop.FileManager1.ShowItems", argument, "string:" }, &output, 1500, a) catch null;
        if (result == null or result.?.exit_code != 0) try files.open(a, std.fs.path.dirname(path) orelse path);
    }
}

test "file dialogs create and rename without overwriting and cancel trash" {
    const a = std.testing.allocator;
    var argc: i32 = 1;
    var arg = "zenkai".*;
    var argv = [_][:0]u8{&arg};
    const app = qt.QApplication.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    const host = qt.QWidget.new2();
    defer host.delete();
    parent = host;
    defer parent = null;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const Probe = struct {
        var name: []const u8 = "";
        var cancel_trash = false;
        var accept_trash = false;
        fn answer(_: qt.QTimer) callconv(.c) void {
            const modal = qt.QApplication.activeModalWidget();
            if (cancel_trash) {
                const dialog = qt.QMessageBox{ .ptr = @ptrCast(modal.ptr) };
                if (accept_trash) dialog.done(qt.qmessagebox_enums.StandardButton.Yes) else dialog.reject();
            } else {
                const dialog = qt.QInputDialog{ .ptr = @ptrCast(modal.ptr) };
                dialog.setTextValue(name);
                dialog.accept();
            }
        }
    };
    const timer = qt.QTimer.new();
    defer timer.delete();
    timer.setSingleShot(true);
    timer.onTimeout(Probe.answer);
    Probe.cancel_trash = false;
    Probe.accept_trash = false;
    Probe.name = "a & 'quoted'.txt";
    timer.start(0);
    const created = (try perform(a, "new_file", root)).?;
    defer a.free(created);
    try std.testing.expect(!try files.isDirectory(created));
    timer.start(0);
    try std.testing.expectError(error.PathAlreadyExists, perform(a, "new_file", root));
    Probe.name = "renamed.txt";
    timer.start(0);
    const renamed = (try perform(a, "rename", created)).?;
    defer a.free(renamed);
    try std.testing.expectError(error.FileNotFound, files.isDirectory(created));
    Probe.cancel_trash = true;
    timer.start(0);
    try std.testing.expect((try perform(a, "trash", renamed)) == null);
    try std.testing.expect(!try files.isDirectory(renamed));
    try std.testing.expect(!isOpen());
    if (std.c.getenv("ZENKAI_TRASH_SMOKE") != null) {
        Probe.accept_trash = true;
        timer.start(0);
        const destination = (try perform(a, "trash", renamed)).?;
        defer a.free(destination);
        try std.testing.expectEqualStrings(root, destination);
        try std.testing.expectError(error.FileNotFound, files.isDirectory(renamed));
    }
}
