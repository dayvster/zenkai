//! Colors read from theme style sheets, shared by the launcher (translucent windows)
//! and the settings window (its own look, swatches and plugin colors).

const std = @import("std");
const qt = @import("libqt6zig");

pub const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    /// Parses `#rgb` or `#rrggbb`; other color syntax (rgba(), palette(), names) gives null.
    pub fn parse(value: []const u8) ?Rgb {
        if (value.len < 1 or value[0] != '#') return null;
        const hex = value[1..];
        const digit = struct {
            fn at(s: []const u8, i: usize, width: usize) ?u8 {
                const n = std.fmt.parseInt(u8, s[i * width ..][0..width], 16) catch return null;
                return if (width == 1) n * 17 else n;
            }
        };
        const width: usize = switch (hex.len) {
            3 => 1,
            6 => 2,
            else => return null,
        };
        return .{
            .r = digit.at(hex, 0, width) orelse return null,
            .g = digit.at(hex, 1, width) orelse return null,
            .b = digit.at(hex, 2, width) orelse return null,
        };
    }

    /// HSL saturation and lightness, each 0 to 1.
    pub fn saturation(self: Rgb) f32 {
        const max = @as(f32, @floatFromInt(@max(self.r, self.g, self.b))) / 255;
        const min = @as(f32, @floatFromInt(@min(self.r, self.g, self.b))) / 255;
        if (max == min) return 0;
        const l = (max + min) / 2;
        return (max - min) / (1 - @abs(2 * l - 1));
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    pub fn luminance(self: Rgb) f32 {
        const linear = struct {
            fn of(channel: u8) f32 {
                const c = @as(f32, @floatFromInt(channel)) / 255;
                return if (c <= 0.03928) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
            }
        };
        return 0.2126 * linear.of(self.r) + 0.7152 * linear.of(self.g) + 0.0722 * linear.of(self.b);
    }

    /// WCAG contrast ratio between two colors, 1 to 21.
    pub fn contrast(self: Rgb, other: Rgb) f32 {
        const a = self.luminance();
        const b = other.luminance();
        return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
    }

    pub fn lightness(self: Rgb) f32 {
        const max: f32 = @floatFromInt(@max(self.r, self.g, self.b));
        const min: f32 = @floatFromInt(@min(self.r, self.g, self.b));
        return (max + min) / 510;
    }

    /// `self` moved `amount` (0 to 1) of the way towards `other`.
    pub fn mix(self: Rgb, other: Rgb, amount: f32) Rgb {
        const blend = struct {
            fn channel(a: u8, b: u8, t: f32) u8 {
                const value = @as(f32, @floatFromInt(a)) * (1 - t) + @as(f32, @floatFromInt(b)) * t;
                return @intFromFloat(@round(value));
            }
        };
        return .{
            .r = blend.channel(self.r, other.r, amount),
            .g = blend.channel(self.g, other.g, amount),
            .b = blend.channel(self.b, other.b, amount),
        };
    }

    pub fn format(self: Rgb, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("#{x:0>2}{x:0>2}{x:0>2}", .{ self.r, self.g, self.b });
    }

    pub fn qcolor(self: Rgb) qt.QColor {
        return qt.QColor.new15(self.r, self.g, self.b, 255);
    }
};

/// The color of `hue` (degrees) at the given HSL saturation and lightness (0 to 1).
pub fn fromHsl(hue: f32, saturation: f32, lightness: f32) Rgb {
    const a = saturation * @min(lightness, 1 - lightness);
    const channel = struct {
        fn at(n: f32, h: f32, l: f32, amount: f32) u8 {
            const k = @mod(n + h / 30, 12);
            const value = l - amount * @max(-1, @min(@min(k - 3, 9 - k), 1));
            return @intFromFloat(@round(value * 255));
        }
    };
    return .{
        .r = channel.at(0, hue, lightness, a),
        .g = channel.at(8, hue, lightness, a),
        .b = channel.at(4, hue, lightness, a),
    };
}

pub const Colors = struct {
    background: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x24 },
    foreground: Rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee },
    field: Rgb = .{ .r = 0x2c, .g = 0x2c, .b = 0x32 },
    accent: Rgb = .{ .r = 0x3d, .g = 0x8b, .b = 0xfd },
};

/// A theme's colors, read from its style sheet. Every theme styles `QWidget` and the
/// launcher's search bar and list, so those rules give the background, text and field
/// colors. The accent lives in different rules per theme (Dracula's is the selected row,
/// the default dark theme's is the focused search bar border), so the most saturated of
/// those candidates is taken as the accent.
pub fn parseColors(qss: []const u8) Colors {
    var colors: Colors = .{};
    if (ruleColor(qss, "QWidget", "background-color")) |rgb| colors.background = rgb;
    if (ruleColor(qss, "QWidget", "color")) |rgb| colors.foreground = rgb;
    if (ruleColor(qss, "#searchbarInput", "background-color")) |rgb| colors.field = rgb;
    const candidates = [_]?Rgb{
        ruleColor(qss, "#searchbarInput:focus", "border-color"),
        ruleColor(qss, "#appList::item:selected", "background"),
        ruleColor(qss, "#appList::item:selected", "background-color"),
        ruleColor(qss, "#searchbarInput", "selection-background-color"),
    };
    var best: ?Rgb = null;
    for (candidates) |candidate| {
        const rgb = candidate orelse continue;
        if (best == null or rgb.saturation() > best.?.saturation()) best = rgb;
    }
    if (best) |rgb| colors.accent = rgb;
    return colors;
}

/// The color `property` gets from the last rule whose selector list contains exactly
/// `selector`, like the cascade: later rules win. Comments before a rule are skipped.
pub fn ruleColor(qss: []const u8, selector: []const u8, property: []const u8) ?Rgb {
    var found: ?Rgb = null;
    var rules = std.mem.splitScalar(u8, qss, '}');
    while (rules.next()) |rule| {
        const open = std.mem.indexOfScalar(u8, rule, '{') orelse continue;
        var selectors = rule[0..open];
        while (std.mem.indexOf(u8, selectors, "*/")) |end| selectors = selectors[end + 2 ..];
        if (!hasSelector(selectors, selector)) continue;
        var declarations = std.mem.splitScalar(u8, rule[open + 1 ..], ';');
        while (declarations.next()) |declaration| {
            const colon = std.mem.indexOfScalar(u8, declaration, ':') orelse continue;
            if (!std.mem.eql(u8, std.mem.trim(u8, declaration[0..colon], " \t\r\n"), property)) continue;
            const value = std.mem.trim(u8, declaration[colon + 1 ..], " \t\r\n");
            const first = value[0 .. std.mem.indexOfAny(u8, value, " \t") orelse value.len];
            if (Rgb.parse(first)) |rgb| found = rgb;
        }
    }
    return found;
}

fn hasSelector(list: []const u8, selector: []const u8) bool {
    var parts = std.mem.splitScalar(u8, list, ',');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, std.mem.trim(u8, part, " \t\r\n"), selector)) return true;
    }
    return false;
}

/// Settings that change the launcher's look on top of its theme.
pub const Appearance = struct {
    /// Background opacity in percent; text and icons stay opaque.
    opacity: i32 = 100,
    corner_radius: i32 = 0,
    /// Result and search text sizes in px; null keeps the theme's.
    font_size: ?i32 = null,
    search_font_size: ?i32 = null,

    /// See-through or rounded windows need a transparent backing (WA_TranslucentBackground)
    /// so the theme's background can be drawn translucent and with round corners.
    pub fn translucent(self: Appearance) bool {
        return self.opacity < 100 or self.corner_radius > 0;
    }
};

/// How a translucent window paints its own background: the theme's background color at the
/// chosen opacity, with rounded corners. See ui/window_background.zig.
pub const WindowBackground = struct {
    color: Rgb,
    alpha: u8,
    radius: i32,
};

pub fn windowBackground(theme_qss: []const u8, appearance: Appearance) WindowBackground {
    return .{
        .color = parseColors(theme_qss).background,
        .alpha = alphaOf(appearance),
        .radius = std.math.clamp(appearance.corner_radius, 0, 64),
    };
}

fn alphaOf(appearance: Appearance) u8 {
    return @intCast(@divTrunc(std.math.clamp(appearance.opacity, 10, 100) * 255, 100));
}

/// Rules appended after the theme for `appearance`; empty when nothing differs from it.
/// A translucent window paints its own background (Qt never draws a top-level widget's style
/// sheet background on a transparent backing), so every widget inside is made transparent,
/// except the search bar and the side panels, which keep their colors at the same opacity.
/// The list's scroll bar is hidden: Qt leaves the strip under it unpainted on a transparent
/// backing, which shows as black. Scrolling still works by wheel and keyboard.
pub fn appearanceStyleSheet(allocator: std.mem.Allocator, theme_qss: []const u8, appearance: Appearance) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (appearance.translucent()) {
        const c = parseColors(theme_qss);
        const alpha = alphaOf(appearance);
        const radius = std.math.clamp(appearance.corner_radius, 0, 64);
        try out.print(allocator,
            \\#mainWindow QWidget {{ background: transparent; }}
            \\#mainWindow #searchbarInput {{ background: rgba({d}, {d}, {d}, {d}); border-top-left-radius: {d}px; border-top-right-radius: {d}px; }}
            \\#mainWindow #actionPanel, #mainWindow #filePreview {{ background: rgba({d}, {d}, {d}, {d}); }}
            \\#mainWindow #appList QScrollBar:vertical {{ width: 0px; }}
            \\
        , .{
            c.field.r,      c.field.g,      c.field.b,      alpha, radius, radius,
            c.background.r, c.background.g, c.background.b, alpha,
        });
    }
    if (appearance.font_size) |size| try out.print(allocator, "#appList {{ font-size: {d}px; }}\n", .{std.math.clamp(size, 6, 72)});
    if (appearance.search_font_size) |size| try out.print(allocator, "#searchbarInput {{ font-size: {d}px; }}\n", .{std.math.clamp(size, 6, 72)});
    return out.toOwnedSlice(allocator);
}

test "appearance rules are empty by default and follow the theme's colors" {
    const a = std.testing.allocator;
    const theme_qss = "QWidget { background-color: #141312; } #searchbarInput { background-color: #2e2c2a; }";

    const none = try appearanceStyleSheet(a, theme_qss, .{});
    defer a.free(none);
    try std.testing.expectEqualStrings("", none);

    const glass = try appearanceStyleSheet(a, theme_qss, .{ .opacity = 80, .corner_radius = 12, .font_size = 15 });
    defer a.free(glass);
    try std.testing.expectEqual(WindowBackground{ .color = .{ .r = 20, .g = 19, .b = 18 }, .alpha = 204, .radius = 12 }, windowBackground(theme_qss, .{ .opacity = 80, .corner_radius = 12 }));
    try std.testing.expect(std.mem.indexOf(u8, glass, "#mainWindow #appList QScrollBar:vertical { width: 0px; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, glass, "#mainWindow #searchbarInput { background: rgba(46, 44, 42, 204);") != null);
    try std.testing.expect(std.mem.indexOf(u8, glass, "#appList { font-size: 15px; }") != null);
    try std.testing.expect(std.mem.indexOf(u8, glass, "#searchbarInput { font-size") == null);

    // Out-of-range values are clamped rather than written as given.
    const clamped = try appearanceStyleSheet(a, theme_qss, .{ .opacity = 0, .corner_radius = 500, .search_font_size = 1 });
    defer a.free(clamped);
    try std.testing.expectEqual(WindowBackground{ .color = .{ .r = 20, .g = 19, .b = 18 }, .alpha = 25, .radius = 64 }, windowBackground(theme_qss, .{ .opacity = 0, .corner_radius = 500 }));
    try std.testing.expect(std.mem.indexOf(u8, clamped, "#searchbarInput { font-size: 6px; }") != null);
}
