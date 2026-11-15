//! Paints a translucent, rounded window background. On a window with a transparent backing
//! (WA_TranslucentBackground) Qt never draws a top-level widget's style sheet background, so
//! the launcher and the settings preview paint the theme's background here instead.

const std = @import("std");
const qt = @import("libqt6zig");
const theme_colors = @import("../theme/colors.zig");

// Paint callbacks carry no user data. One process paints at most one such window at a time
// (the launcher, or the settings preview's stand-in), so a single setting is enough.
var g_background: theme_colors.WindowBackground = .{ .color = .{}, .alpha = 255, .radius = 0 };

/// Sets what install()ed windows paint; call `update()` on them to repaint.
pub fn configure(background: theme_colors.WindowBackground) void {
    g_background = background;
}

/// Gives `window` a translucent backing and paints the configured background behind its
/// children.
pub fn install(window: qt.QWidget) void {
    window.setAttribute2(qt.qnamespace_enums.WidgetAttribute.WA_TranslucentBackground, true);
    window.onPaintEvent(paint);
}

fn paint(window: qt.QWidget, _: qt.QPaintEvent) callconv(.c) void {
    const painter = qt.QPainter.new2(window);
    defer painter.delete();
    painter.setRenderHint(qt.qpainter_enums.RenderHint.Antialiasing);
    painter.setPen3(qt.qnamespace_enums.PenStyle.NoPen);
    const c = g_background.color;
    const color = qt.QColor.new15(c.r, c.g, c.b, g_background.alpha);
    defer color.delete();
    const brush = qt.QBrush.new3(color);
    defer brush.delete();
    painter.setBrush(brush);
    const radius: f64 = @floatFromInt(g_background.radius);
    painter.drawRoundedRect2(0, 0, window.width(), window.height(), radius, radius);
    _ = painter.end();
}
