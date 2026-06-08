const std = @import("std");
const qt = @import("libqt6zig");
const theme = @import("../theme/theme.zig");
const config = @import("config");

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
    const highlight = hexToQColor(colors.highlight);
    const accent = hexToQColor(colors.accent);

    var palette = QPalette.New();
    defer palette.Delete();

    palette.SetColor2(qpalette.ColorRole.Window, bg);
    palette.SetColor2(qpalette.ColorRole.WindowText, fg);
    palette.SetColor2(qpalette.ColorRole.Base, bg);
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

fn generateQSS(vis: config.VisualConfig, colors: theme.Colors, allocator: std.mem.Allocator) ![]u8 {
    var parts: [8][]const u8 = undefined;

    parts[0] = try std.fmt.allocPrint(allocator,
        \\QWidget {{
        \\    font-family: {s};
        \\    font-size: {d}px;
        \\    background-color: {s};
        \\    color: {s};
        \\}}
        \\
    , .{ vis.font_family, vis.font_size, colors.bg, colors.text });

    parts[1] = try std.fmt.allocPrint(allocator,
        \\#searchbarInput {{
        \\    font-size: {d}px;
        \\    padding: {d}px {d}px {d}px {d}px;
        \\    border-width: {d}px;
        \\    border-style: solid;
        \\    border-radius: {d}px;
        \\    background-color: {s};
        \\    color: {s};
        \\    border-color: {s};
        \\    selection-background-color: {s};
        \\    selection-color: {s};
        \\}}
        \\
        \\#searchbarInput:focus {{
        \\    border-color: {s};
        \\}}
        \\
        \\#searchbarInput::placeholder {{
        \\    color: {s};
        \\}}
        \\
    , .{
        vis.search_font_size,
        vis.search_padding_top,
        vis.search_padding_right,
        vis.search_padding_bottom,
        vis.search_padding_left,
        vis.search_border_width,
        vis.search_border_radius,
        colors.surface,
        colors.text,
        colors.border,
        colors.highlight,
        colors.text,
        colors.accent,
        colors.muted,
    });

    parts[2] = try std.fmt.allocPrint(allocator,
        \\#appList {{
        \\    border: none;
        \\    outline: none;
        \\    padding: 0px;
        \\    font-size: {d}px;
        \\}}
        \\
    , .{
        vis.list_font_size,
    });

    parts[3] = try std.fmt.allocPrint(allocator,
        \\#appList::item {{
        \\    padding: {d}px {d}px {d}px {d}px;
        \\    border-radius: {d}px;
        \\}}
        \\
    , .{
        vis.list_item_padding_top,    vis.list_item_padding_right,
        vis.list_item_padding_bottom, vis.list_item_padding_left,
        vis.list_item_border_radius,
    });

    parts[4] = try std.fmt.allocPrint(allocator,
        \\#appList QScrollBar:vertical {{
        \\    width: {d}px;
        \\    margin: 0;
        \\    border-radius: {d}px;
        \\    background-color: transparent;
        \\}}
        \\
        \\#appList QScrollBar::handle:vertical {{
        \\    min-height: {d}px;
        \\    border-radius: {d}px;
        \\    background-color: {s};
        \\}}
        \\
        \\#appList QScrollBar::handle:vertical:hover {{
        \\    background-color: {s};
        \\}}
        \\
        \\#appList QScrollBar::add-line:vertical,
        \\#appList QScrollBar::sub-line:vertical {{
        \\    height: 0;
        \\}}
        \\
        \\#appList QScrollBar::add-page:vertical,
        \\#appList QScrollBar::sub-page:vertical {{
        \\    background: none;
        \\}}
        \\
    , .{
        vis.scrollbar_width,
        vis.scrollbar_border_radius,
        vis.scrollbar_handle_min_height,
        vis.scrollbar_border_radius,
        colors.border,
        colors.highlight,
    });

    parts[5] = try std.fmt.allocPrint(allocator,
        \\#bottomBar QLabel {{
        \\    border: none;
        \\    font-size: {d}px;
        \\    padding-right: 8px;
        \\    color: {s};
        \\}}
        \\
    , .{ vis.label_font_size, colors.muted });

    parts[6] = try std.fmt.allocPrint(allocator,
        \\#bottomBar QToolButton {{
        \\    border: none;
        \\    padding: {d}px {d}px {d}px {d}px;
        \\    font-size: {d}px;
        \\    border-radius: {d}px;
        \\    background: transparent;
        \\}}
        \\
        \\#bottomBar QToolButton:hover {{
        \\    background-color: {s};
        \\}}
        \\
    , .{
        vis.button_padding_top, vis.button_padding_right, vis.button_padding_bottom, vis.button_padding_left,
        vis.button_font_size,   vis.button_border_radius, colors.surface,
    });

    parts[7] = "\n";

    defer for (0..7) |i| allocator.free(parts[i]);

    return std.mem.concat(allocator, u8, &parts);
}

pub fn apply(
    allocator: std.mem.Allocator,
    vis: config.VisualConfig,
    theme_qss: ?[]const u8,
    theme_colors: theme.Colors,
) void {
    _ = QAppType.SetStyle2("Fusion");

    QAppType.SetEffectEnabled2(0, false);
    QAppType.SetEffectEnabled2(1, false);
    QAppType.SetEffectEnabled2(2, false);
    QAppType.SetEffectEnabled2(3, false);
    QAppType.SetEffectEnabled2(4, false);
    QAppType.SetEffectEnabled2(5, false);
    QAppType.SetEffectEnabled2(6, false);

    applyPalette(theme_colors);

    const generated = generateQSS(vis, theme_colors, allocator) catch return;
    defer allocator.free(generated);

    if (theme_qss) |extra| {
        if (std.mem.concat(allocator, u8, &.{ generated, extra })) |combined| {
            defer allocator.free(combined);
            g_qapp.SetStyleSheet(combined);
        } else |_| {
            g_qapp.SetStyleSheet(generated);
        }
    } else {
        g_qapp.SetStyleSheet(generated);
    }
}
