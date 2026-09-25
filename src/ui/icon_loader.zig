const builtin = @import("builtin");
const qt = @import("libqt6zig");

const QIcon = qt.QIcon;
const shell_icon_prefix = "windows-shell:";
const appsfolder_icon_prefix = "windows-app:";

/// Resolve the icon Windows associates with a shortcut through Qt's native
/// file icon provider. Theme names and image paths keep their normal behavior.
pub fn load(icon_name: []const u8) QIcon {
    if (icon_name.len == 0) return QIcon.new();

    if (comptime builtin.os.tag == .windows) {
        if (std.mem.startsWith(u8, icon_name, shell_icon_prefix)) {
            const QFileInfo = qt.QFileInfo;
            const QFileIconProvider = qt.QFileIconProvider;
            const info = QFileInfo.new2(icon_name[shell_icon_prefix.len..]);
            defer info.delete();
            const provider = QFileIconProvider.new();
            defer provider.delete();
            return provider.icon2(info);
        }
        if (std.mem.startsWith(u8, icon_name, appsfolder_icon_prefix)) {
            const QFileInfo = qt.QFileInfo;
            const QFileIconProvider = qt.QFileIconProvider;
            const shell_path = std.fmt.allocPrint(std.heap.page_allocator, "shell:AppsFolder\\{s}", .{icon_name[appsfolder_icon_prefix.len..]}) catch return QIcon.new();
            defer std.heap.page_allocator.free(shell_path);
            const info = QFileInfo.new2(shell_path);
            defer info.delete();
            const provider = QFileIconProvider.new();
            defer provider.delete();
            return provider.icon2(info);
        }
    }

    if (icon_name[0] == '/' or isWindowsAbsolutePath(icon_name)) return QIcon.new4(icon_name);
    return QIcon.fromTheme(icon_name);
}

fn isWindowsAbsolutePath(path: []const u8) bool {
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

const std = @import("std");
