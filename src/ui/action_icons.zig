const std = @import("std");
const qt = @import("libqt6zig");

const Asset = struct {
    name: []const u8,
    svg: []const u8,
};

// These are empty placeholders in src/assets/icons/actions/. Replace a file
// with any SVG; its contents are embedded at build time. SVGs may use
// `currentColor` (or `inherit`) for fills/strokes to follow the active theme's
// text color. Hard-coded colors are left untouched.
const assets = [_]Asset{
    .{ .name = "document-open", .svg = @embedFile("../assets/icons/actions/document-open.svg") },
    .{ .name = "preferences-system-windows", .svg = @embedFile("../assets/icons/actions/preferences-system-windows.svg") },
    .{ .name = "window-left-half", .svg = @embedFile("../assets/icons/actions/window-left-half.svg") },
    .{ .name = "window-right-half", .svg = @embedFile("../assets/icons/actions/window-right-half.svg") },
    .{ .name = "window-top-half", .svg = @embedFile("../assets/icons/actions/window-top-half.svg") },
    .{ .name = "window-bottom-half", .svg = @embedFile("../assets/icons/actions/window-bottom-half.svg") },
    .{ .name = "window-maximize", .svg = @embedFile("../assets/icons/actions/window-maximize.svg") },
    .{ .name = "window-center", .svg = @embedFile("../assets/icons/actions/window-center.svg") },
    .{ .name = "window-next-display", .svg = @embedFile("../assets/icons/actions/window-next-display.svg") },
    .{ .name = "window-new", .svg = @embedFile("../assets/icons/actions/window-new.svg") },
    .{ .name = "view-private", .svg = @embedFile("../assets/icons/actions/view-private.svg") },
    .{ .name = "edit-copy", .svg = @embedFile("../assets/icons/actions/edit-copy.svg") },
    .{ .name = "edit-copy-command", .svg = @embedFile("../assets/icons/actions/edit-copy-command.svg") },
    .{ .name = "dialog-information", .svg = @embedFile("../assets/icons/actions/dialog-information.svg") },
    .{ .name = "view-refresh", .svg = @embedFile("../assets/icons/actions/view-refresh.svg") },
    .{ .name = "application-x-executable", .svg = @embedFile("../assets/icons/actions/application-x-executable.svg") },
};

fn find(name: []const u8) ?[]const u8 {
    inline for (assets) |asset| {
        if (std.mem.eql(u8, name, asset.name)) return asset.svg;
    }
    return null;
}

pub fn has(name: []const u8) bool {
    return find(name) != null;
}

fn usesThemeColor(svg: []const u8) bool {
    return std.mem.indexOf(u8, svg, "currentColor") != null or
        std.mem.indexOf(u8, svg, "inherit") != null;
}

fn resolveThemeColor(svg: []const u8, color: []const u8) ?[]u8 {
    var resolved = std.mem.replaceOwned(u8, std.heap.page_allocator, svg, "currentColor", color) catch return null;
    if (std.mem.indexOf(u8, resolved, "inherit") != null) {
        const next = std.mem.replaceOwned(u8, std.heap.page_allocator, resolved, "inherit", color) catch {
            std.heap.page_allocator.free(resolved);
            return null;
        };
        std.heap.page_allocator.free(resolved);
        resolved = next;
    }
    return resolved;
}

fn render(svg: []const u8, color: ?[]const u8, extent: i32, bounds: qt.QRectF) ?qt.QPixmap {
    const resolved = if (color) |hex| resolveThemeColor(svg, hex) else null;
    defer if (resolved) |buf| std.heap.page_allocator.free(buf);

    const renderer = qt.QSvgRenderer.new3(resolved orelse svg);
    defer renderer.delete();
    if (!renderer.isValid()) return null;

    const pixmap = qt.QPixmap.new2(extent, extent);
    const transparent = qt.QColor.new15(0, 0, 0, 0);
    defer transparent.delete();
    pixmap.fill1(transparent);

    const painter = qt.QPainter.new();
    defer painter.delete();
    if (!painter.begin(pixmap)) {
        pixmap.delete();
        return null;
    }
    defer _ = painter.end();
    painter.setRenderHint(1);
    renderer.render2(painter, bounds);
    return pixmap;
}

/// Render an embedded SVG at the menu's physical scale. Returning a pixmap at
/// physical size keeps the glyph sharp on HiDPI screens without clipping it.
/// `currentColor`/`inherit` resolves to the menu's text color; selected items
/// use the highlighted text color.
pub fn load(menu: qt.QMenu, name: []const u8) ?qt.QIcon {
    const svg = find(name) orelse return null;
    if (svg.len == 0) return null;

    const screen = menu.screen();
    const ratio = @max(screen.devicePixelRatio(), 1.0);
    const extent: i32 = @intFromFloat(@round(24.0 * ratio));
    const bounds = qt.QRectF.new6(0, 0, @floatFromInt(extent), @floatFromInt(extent));
    defer bounds.delete();

    if (!usesThemeColor(svg)) {
        const normal = render(svg, null, extent, bounds) orelse return null;
        defer normal.delete();
        return qt.QIcon.new2(normal);
    }

    const palette = menu.palette();
    const normal_color = palette.color2(qt.qpalette_enums.ColorRole.WindowText);
    const normal_hex = normal_color.name(std.heap.page_allocator);
    defer std.heap.page_allocator.free(normal_hex);

    const normal = render(svg, normal_hex, extent, bounds) orelse return null;
    defer normal.delete();
    const icon = qt.QIcon.new2(normal);

    const selected_color = palette.color2(qt.qpalette_enums.ColorRole.HighlightedText);
    const selected_hex = selected_color.name(std.heap.page_allocator);
    defer std.heap.page_allocator.free(selected_hex);
    if (std.mem.eql(u8, normal_hex, selected_hex)) return icon;

    const selected = render(svg, selected_hex, extent, bounds) orelse return icon;
    defer selected.delete();
    icon.addPixmap2(selected, qt.qicon_enums.Mode.Active);
    icon.addPixmap2(selected, qt.qicon_enums.Mode.Selected);
    return icon;
}

test "built-in action icons are embedded" {
    try std.testing.expect(has("edit-copy"));
    try std.testing.expect(has("edit-copy-command"));
    try std.testing.expect(has("window-left-half"));
    try std.testing.expect(!has("not-an-action-icon"));
}
