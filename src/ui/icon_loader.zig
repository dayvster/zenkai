const builtin = @import("builtin");
const qt = @import("libqt6zig");

const QIcon = qt.QIcon;
const shell_icon_prefix = "windows-shell:";
const appsfolder_icon_prefix = "windows-app:";

/// Resolve the icon Windows associates with a shortcut through Qt's native
/// file icon provider. Theme names and image paths keep their normal behavior.
pub fn load(icon_name: []const u8) QIcon {
    if (icon_name.len == 0) return QIcon.new();

    if (std.mem.startsWith(u8, icon_name, glyph_prefix)) return glyph(icon_name[glyph_prefix.len..]);

    if (std.mem.startsWith(u8, icon_name, "native-file:")) {
        const info = qt.QFileInfo.new2(icon_name["native-file:".len..]);
        defer info.delete();
        const provider = qt.QFileIconProvider.new();
        defer provider.delete();
        return provider.icon2(info);
    }

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

/// `glyph:<text>` draws a short piece of text, typically an emoji, as the icon.
/// It is rendered large and scaled down by Qt, so it stays sharp at any icon size.
pub const glyph_prefix = "glyph:";
const glyph_extent = 128;

fn glyph(text: []const u8) QIcon {
    if (text.len == 0) return QIcon.new();
    const pixmap = qt.QPixmap.new2(glyph_extent, glyph_extent);
    defer pixmap.delete();
    const transparent = qt.QColor.new15(0, 0, 0, 0);
    defer transparent.delete();
    pixmap.fill1(transparent);

    const painter = qt.QPainter.new();
    defer painter.delete();
    if (!painter.begin(pixmap)) return QIcon.new();
    painter.setRenderHint(1); // antialiasing
    const font = qt.QFont.new();
    defer font.delete();
    font.setPixelSize(glyph_extent * 3 / 4);
    painter.setFont(font);
    const rect = qt.QRect.new6(0, 0, glyph_extent, glyph_extent);
    defer rect.delete();
    painter.drawText6(rect, 0x84, text); // Qt::AlignCenter
    _ = painter.end();
    return QIcon.new2(pixmap);
}

fn isWindowsAbsolutePath(path: []const u8) bool {
    return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

const std = @import("std");
