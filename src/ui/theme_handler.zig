const std = @import("std");
const qt = @import("libqt6zig");
const theme = @import("../theme/theme.zig");

const main_qss = @embedFile("../styles/main.qss");

const QAppType = qt.QApplication;
var g_qapp: qt.QApplication = undefined;

pub fn setApp(app: qt.QApplication) void {
    g_qapp = app;
}

const QPalette = qt.QPalette;
const QColor = qt.QColor;
const qpalette = qt.qpalette_enums;

fn hexToQColor(hex: []const u8) QColor {
    const s = if (hex[0] == '#') hex[1..] else hex;
    return QColor.New5(
        std.fmt.parseInt(u8, s[0..2], 16) catch unreachable,
        std.fmt.parseInt(u8, s[2..4], 16) catch unreachable,
        std.fmt.parseInt(u8, s[4..6], 16) catch unreachable,
    );
}

fn applyPalette(colors: theme.Colors) void {
    const bg = hexToQColor(colors.bg);
    const bg_light = hexToQColor(colors.surface);
    const border = hexToQColor(colors.border);
    const fg = hexToQColor(colors.text);
    const placeholder = hexToQColor(colors.muted);
    const highlight = QColor.New5(0x58, 0x5b, 0x70);
    const accent = hexToQColor(colors.accent);

    var palette = QPalette.New();
    defer palette.Delete();

    palette.SetColor2(qpalette.ColorRole.Window, bg);
    palette.SetColor2(qpalette.ColorRole.WindowText, fg);
    palette.SetColor2(qpalette.ColorRole.Base, bg_light);
    palette.SetColor2(qpalette.ColorRole.Text, fg);
    palette.SetColor2(qpalette.ColorRole.Button, border);
    palette.SetColor2(qpalette.ColorRole.ButtonText, fg);
    palette.SetColor2(qpalette.ColorRole.Highlight, highlight);
    palette.SetColor2(qpalette.ColorRole.HighlightedText, fg);
    palette.SetColor2(qpalette.ColorRole.PlaceholderText, placeholder);
    palette.SetColor2(qpalette.ColorRole.Light, bg_light);
    palette.SetColor2(qpalette.ColorRole.Accent, accent);

    bg.Delete();
    bg_light.Delete();
    border.Delete();
    fg.Delete();
    placeholder.Delete();
    highlight.Delete();
    accent.Delete();

    QAppType.SetPalette(palette);
}

pub fn apply(
    allocator: std.mem.Allocator,
    theme_qss: []const u8,
    theme_colors: theme.Colors,
) void {
    QAppType.SetEffectEnabled2(0, false);
    QAppType.SetEffectEnabled2(1, false);
    QAppType.SetEffectEnabled2(2, false);
    QAppType.SetEffectEnabled2(3, false);
    QAppType.SetEffectEnabled2(4, false);
    QAppType.SetEffectEnabled2(5, false);
    QAppType.SetEffectEnabled2(6, false);

    applyPalette(theme_colors);

    const qss = std.mem.concat(allocator, u8, &.{ main_qss, theme_qss }) catch return;
    defer allocator.free(qss);
    g_qapp.SetStyleSheet(qss);
}
