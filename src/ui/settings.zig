//! The settings window (`zenkai --settings`). It edits the config file zenkai reads at
//! startup; every change is saved straight away and applies the next time the launcher opens.
//!
//! The look is generated from the active theme: `themeColors` reads the colors a theme gives
//! the launcher's search bar, and `styleSheet` builds this window's cards, sidebar and inputs
//! from them, so every theme gets a matching settings window without its own rules.

const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");
const plugins = @import("plugins");
const lang = @import("lang");
const log = @import("utils").log;
const theme = @import("../theme/theme.zig");
const icons = @import("icon_loader.zig");
const action_icons = @import("action_icons.zig");
const EasingType = @import("animation.zig").EasingType;

const Page = enum { appearance, behaviour, animations, integrations };

/// Rows are grouped into cards; each card belongs to one page.
const Card = enum {
    theme,
    size,
    spacing,
    window,
    results,
    motion,
    commands,

    fn page(card: Card) Page {
        return switch (card) {
            .theme, .size, .spacing => .appearance,
            .window, .results => .behaviour,
            .motion => .animations,
            .commands => .integrations,
        };
    }
};

/// One editable config key; `key` is both the VisualConfig field and the config file key.
/// The control follows the field's type: bool is a switch, i32 a number field, ?i32 a number
/// field whose lowest value means "not set", and ?[]const u8 a dropdown when `choices` is
/// given, otherwise a text field. Leaving a dropdown or text field empty removes the key.
const Field = struct {
    key: []const u8,
    card: Card,
    min: i32 = 0,
    max: i32 = 0,
    suffix: []const u8 = "",
    choices: []const []const u8 = &.{},
    placeholder: []const u8 = "",
};

const theme_names = blk: {
    var names: [theme.theme_entries.len][]const u8 = undefined;
    for (theme.theme_entries, 0..) |entry, i| names[i] = entry.name;
    break :blk names;
};

// In display order: cards appear in the order of their first field.
const fields = [_]Field{
    .{ .key = "theme", .card = .theme, .choices = &theme_names },
    .{ .key = "icon_size", .card = .size, .min = 16, .max = 128, .suffix = " px" },
    .{ .key = "window_width", .card = .size, .min = 300, .max = 4000, .suffix = " px" },
    .{ .key = "window_height", .card = .size, .min = 200, .max = 3000, .suffix = " px" },
    .{ .key = "layout_margin", .card = .spacing, .max = 64, .suffix = " px" },
    .{ .key = "layout_spacing", .card = .spacing, .max = 64, .suffix = " px" },
    .{ .key = "close_on_focus_out", .card = .window },
    .{ .key = "show_backdrop", .card = .window },
    .{ .key = "fullscreen", .card = .window },
    .{ .key = "monitor", .card = .window, .min = -1, .max = 15 },
    .{ .key = "file_previews", .card = .results },
    .{ .key = "no_animations", .card = .motion },
    .{ .key = "animation_interval", .card = .motion, .max = 2000, .suffix = " ms" },
    .{ .key = "animation_easing", .card = .motion, .choices = &EasingType.names },
    .{ .key = "clipboard", .card = .commands, .placeholder = "wl-copy" },
    .{ .key = "url_handler", .card = .commands, .placeholder = "xdg-open" },
};

// Sidebar line icons on a 24px grid, drawn in the theme's text color (`currentColor`).
const icon_attributes = "xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\"";
const page_icons = [_][]const u8{
    // Appearance: a palette.
    "<svg " ++ icon_attributes ++ "><path d=\"M12 3.5a8.5 8.5 0 1 0 0 17c1 0 1.6-.7 1.6-1.5 0-.4-.2-.8-.5-1.1-.3-.3-.5-.7-.5-1.1 0-.9.7-1.5 1.6-1.5h1.8a4.5 4.5 0 0 0 4.5-4.5c0-4-3.8-7.3-8.5-7.3Z\"/><circle cx=\"7.5\" cy=\"11.5\" r=\"1\" fill=\"currentColor\"/><circle cx=\"10\" cy=\"7.5\" r=\"1\" fill=\"currentColor\"/><circle cx=\"14.5\" cy=\"7.5\" r=\"1\" fill=\"currentColor\"/></svg>",
    // Behaviour: a window.
    "<svg " ++ icon_attributes ++ "><rect x=\"3\" y=\"4.5\" width=\"18\" height=\"15\" rx=\"2.5\"/><path d=\"M3 9h18\"/><path d=\"M6.5 6.8h.01M9 6.8h.01\"/></svg>",
    // Animations: a ball with speed lines.
    "<svg " ++ icon_attributes ++ "><circle cx=\"15.5\" cy=\"12\" r=\"4.5\"/><path d=\"M3 8.5h6M2 12h6.5M3 15.5h6\"/></svg>",
    // Integrations: a terminal prompt.
    "<svg " ++ icon_attributes ++ "><rect x=\"3\" y=\"4.5\" width=\"18\" height=\"15\" rx=\"2.5\"/><path d=\"m7 10 3 2.5L7 15M12.5 15H17\"/></svg>",
};
// Plugins: three blocks and a plus.
const plugins_icon = "<svg " ++ icon_attributes ++ "><rect x=\"4\" y=\"4\" width=\"6.5\" height=\"6.5\" rx=\"1.5\"/><rect x=\"13.5\" y=\"4\" width=\"6.5\" height=\"6.5\" rx=\"1.5\"/><rect x=\"4\" y=\"13.5\" width=\"6.5\" height=\"6.5\" rx=\"1.5\"/><path d=\"M16.75 13.5v6.5M13.5 16.75H20\"/></svg>";
// One per sidebar row, in order: the pages, then Plugins.
const nav_icons = page_icons ++ [_][]const u8{plugins_icon};

// Every input has the same width so their edges line up down a card.
const input_width = 220;

const Control = union(enum) {
    toggle: qt.QCheckBox,
    spin: qt.QSpinBox,
    combo: qt.QComboBox,
    text: qt.QLineEdit,
};

const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    // Apply sets the chosen theme on the app as well as this window.
    app: qt.QApplication,
    window: qt.QWidget,
    nav: qt.QListWidget = undefined,
    pages: qt.QStackedWidget,
    status: qt.QLabel,
    apply_button: qt.QPushButton = undefined,
    controls: [fields.len]Control,
    // One switch per installed plugin, in `installed` order.
    plugin_switches: []qt.QCheckBox,
    // Each plugin's name label, also in `installed` order; restyle colors them.
    plugin_titles: []qt.QLabel = &.{},
    installed: []const plugins.PluginInfo,
    // Disabled names with no installed plugin, kept so saving doesn't silently drop them.
    disabled: []const []const u8,
    preview: Preview = undefined,
    // Set while the window fills in values, so those changes don't count as edits.
    loading: bool = false,
    // Edits made since the last Apply.
    dirty: bool = false,
};

// Qt callbacks carry no user data, so they reach the open window through these.
var g_state: ?*State = null;
var g_colors: Colors = .{};

fn text(comptime key: []const u8) []const u8 {
    return @field(lang.get(), "settings_" ++ key);
}

/// Opens the window and runs until it closes. `app` already has the theme applied.
pub fn run(allocator: std.mem.Allocator, app: qt.QApplication) !void {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const active_qss = app.styleSheet(allocator);
    defer allocator.free(active_qss);
    const path = try config.deploy(io, allocator);
    defer allocator.free(path);
    // Read the file itself: the window edits what is saved, not what flags override.
    var cfg = try config.loadConfig(allocator, path);
    defer cfg.deinit(allocator);
    const installed = plugins.listPlugins(allocator, io) catch &.{};
    defer if (installed.len > 0) plugins.freePluginList(allocator, installed);

    var state: State = .{
        .allocator = allocator,
        .io = io,
        .path = path,
        .app = app,
        .window = undefined,
        .pages = undefined,
        .status = undefined,
        .controls = undefined,
        .plugin_switches = &.{},
        .installed = installed,
        .disabled = cfg.disabled_plugins,
    };
    try build(&state, active_qss);
    defer destroy(&state);
    showValues(&state, cfg);

    g_state = &state;
    defer g_state = null;
    state.window.show();
    _ = qt.QApplication.exec();
}

fn destroy(state: *State) void {
    state.preview.deinit();
    state.window.delete();
    state.allocator.free(state.plugin_switches);
    state.allocator.free(state.plugin_titles);
}

// Theme colors ----------------------------------------------------------------

const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    /// Parses `#rgb` or `#rrggbb`; other color syntax (rgba(), palette(), names) gives null.
    fn parse(value: []const u8) ?Rgb {
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
    fn saturation(self: Rgb) f32 {
        const max = @as(f32, @floatFromInt(@max(self.r, self.g, self.b))) / 255;
        const min = @as(f32, @floatFromInt(@min(self.r, self.g, self.b))) / 255;
        if (max == min) return 0;
        const l = (max + min) / 2;
        return (max - min) / (1 - @abs(2 * l - 1));
    }

    /// WCAG relative luminance, 0 (black) to 1 (white).
    fn luminance(self: Rgb) f32 {
        const linear = struct {
            fn of(channel: u8) f32 {
                const c = @as(f32, @floatFromInt(channel)) / 255;
                return if (c <= 0.03928) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
            }
        };
        return 0.2126 * linear.of(self.r) + 0.7152 * linear.of(self.g) + 0.0722 * linear.of(self.b);
    }

    /// WCAG contrast ratio between two colors, 1 to 21.
    fn contrast(self: Rgb, other: Rgb) f32 {
        const a = self.luminance();
        const b = other.luminance();
        return (@max(a, b) + 0.05) / (@min(a, b) + 0.05);
    }

    fn lightness(self: Rgb) f32 {
        const max: f32 = @floatFromInt(@max(self.r, self.g, self.b));
        const min: f32 = @floatFromInt(@min(self.r, self.g, self.b));
        return (max + min) / 510;
    }

    /// `self` moved `amount` (0 to 1) of the way towards `other`.
    fn mix(self: Rgb, other: Rgb, amount: f32) Rgb {
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

    fn qcolor(self: Rgb) qt.QColor {
        return qt.QColor.new15(self.r, self.g, self.b, 255);
    }
};

/// The color of `hue` (degrees) at the given HSL saturation and lightness (0 to 1).
fn fromHsl(hue: f32, saturation: f32, lightness: f32) Rgb {
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

/// The color of the `index`th plugin name in the (sorted) list. Hues step by the golden
/// angle, which keeps neighbours far apart for any number of plugins; hashing names left
/// some pairs a degree apart. HSL lightness isn't perceptual (yellow looks far lighter than
/// blue at the same value), so the lightness steps away from the background until the name
/// reaches 4.5:1 contrast, the WCAG AA level for text.
fn pluginColor(index: usize, background: Rgb) Rgb {
    const hue = pluginHue(index);
    const dark_theme = background.lightness() < 0.5;
    var lightness: f32 = if (dark_theme) 0.68 else 0.42;
    while (true) : (lightness += if (dark_theme) 0.02 else -0.02) {
        const color = fromHsl(hue, 0.65, lightness);
        if (color.contrast(background) >= 4.5 or lightness <= 0.05 or lightness >= 0.95) return color;
    }
}

fn pluginHue(index: usize) f32 {
    const golden_angle = 137.508;
    return @floatCast(@mod(20 + @as(f64, @floatFromInt(index)) * golden_angle, 360));
}

const Colors = struct {
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
fn parseColors(qss: []const u8) Colors {
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
fn ruleColor(qss: []const u8, selector: []const u8, property: []const u8) ?Rgb {
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

/// The colors of a theme by name (null for the default), resolved as the launcher would.
fn themeColorsFor(allocator: std.mem.Allocator, name: ?[]const u8) Colors {
    const resolved = if (name != null and std.mem.eql(u8, name.?, "native"))
        theme.resolveNative(allocator)
    else
        theme.resolve(allocator, name);
    defer if (resolved.allocation) |memory| allocator.free(memory);
    return parseColors(resolved.qss);
}

/// QSS draws a dropdown arrow only from an image file, so a chevron in the theme's text color
/// is written to the cache directory. Returns null when that fails; dropdowns then have no arrow.
fn writeArrow(allocator: std.mem.Allocator, io: std.Io, color: Rgb) ?[]u8 {
    const dir = config.userCacheDir(allocator) catch return null;
    defer allocator.free(dir);
    @import("utils").fsutils.makeDir(io, dir) catch return null;
    const path = std.fs.path.join(allocator, &.{ dir, "settings-arrow.svg" }) catch return null;
    const svg = std.fmt.allocPrint(allocator,
        \\<svg xmlns="http://www.w3.org/2000/svg" width="12" height="8" viewBox="0 0 12 8"><path d="M1.5 1.5 6 6l4.5-4.5" fill="none" stroke="{f}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>
    , .{color}) catch {
        allocator.free(path);
        return null;
    };
    defer allocator.free(svg);
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = svg }) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

fn styleSheet(allocator: std.mem.Allocator, c: Colors, arrow: []const u8) ![]u8 {
    const bg = c.background;
    const fg = c.foreground;
    return std.fmt.allocPrint(allocator,
        \\#settingsWindow {{ background: {[bg]f}; }}
        \\#settingsWindow QLabel {{ background: transparent; color: {[fg]f}; }}
        \\#settingsSidebar {{ background: {[sidebar]f}; border-right: 1px solid {[line]f}; }}
        \\#settingsBrand {{ font-size: 17px; font-weight: 700; }}
        \\#settingsBrandSub {{ color: {[muted]f}; font-size: 12px; }}
        \\#settingsNav {{ background: transparent; border: none; outline: 0; font-size: 14px; }}
        \\#settingsNav::item {{ color: {[fg]f}; padding: 8px 10px; margin: 1px 0; border-radius: 8px; }}
        \\#settingsNav::item:hover {{ background: {[hover]f}; }}
        \\#settingsNav::item:selected {{ background: {[selected]f}; color: {[fg]f}; }}
        \\#settingsScroll, #settingsScroll > QWidget, #settingsPage {{ background: {[bg]f}; border: none; }}
        \\#settingsTitle {{ font-size: 24px; font-weight: 700; }}
        \\#settingsDescription {{ color: {[muted]f}; font-size: 13px; }}
        \\#settingsCardTitle {{ color: {[muted]f}; font-size: 11px; font-weight: 700; }}
        \\#settingsCard {{ background: {[surface]f}; border: 1px solid {[line]f}; border-radius: 12px; }}
        \\#settingsDivider {{ background: {[line]f}; border: none; }}
        \\#settingsRowTitle {{ font-size: 14px; }}
        \\#settingsRowHint {{ color: {[muted]f}; font-size: 12px; }}
        \\#settingsCard QSpinBox, #settingsCard QComboBox, #settingsCard QLineEdit {{
        \\    background: {[field]f}; color: {[fg]f}; border: 1px solid {[line]f}; border-radius: 8px;
        \\    padding: 6px 10px; selection-background-color: {[accent]f};
        \\}}
        \\#settingsCard QSpinBox:focus, #settingsCard QComboBox:focus, #settingsCard QLineEdit:focus {{ border-color: {[accent]f}; }}
        \\#settingsCard QSpinBox {{ padding: 0; }}
        \\#settingsCard QSpinBox::up-button, #settingsCard QSpinBox::down-button {{ width: 0; border: none; }}
        \\#settingsCard QSpinBox QLineEdit {{ background: transparent; border: none; padding: 0; min-width: 0; }}
        \\#settingsCard QComboBox::drop-down {{ border: none; width: 28px; }}
        \\#settingsCard QComboBox::down-arrow {{ image: url({[arrow]s}); width: 12px; height: 8px; }}
        \\#settingsCard QComboBox QAbstractItemView {{
        \\    background: {[field]f}; color: {[fg]f}; border: 1px solid {[line]f}; border-radius: 8px;
        \\    padding: 4px; outline: 0; selection-background-color: {[selected]f}; selection-color: {[fg]f};
        \\}}
        \\#settingsPreview {{ border: 1px solid {[line]f}; padding: 0; }}
        \\#settingsFooter {{ background: {[bg]f}; border-top: 1px solid {[line]f}; }}
        \\#settingsStatus {{ color: {[muted]f}; font-size: 12px; }}
        \\#settingsButton {{ background: transparent; color: {[fg]f}; border: 1px solid {[line]f}; border-radius: 8px; padding: 7px 14px; }}
        \\#settingsButton:hover {{ background: {[hover]f}; }}
        \\#settingsApply {{ background: {[accent]f}; color: {[on_accent]f}; border: 1px solid {[accent]f}; border-radius: 8px; padding: 7px 20px; font-weight: 600; }}
        \\#settingsApply:hover {{ background: {[accent_hover]f}; }}
        \\#settingsApply:disabled {{ background: transparent; color: {[muted]f}; border: 1px solid {[line]f}; font-weight: 400; }}
        \\#settingsWindow QScrollBar:vertical {{ background: transparent; width: 8px; margin: 4px 2px; }}
        \\#settingsWindow QScrollBar::handle:vertical {{ background: {[line]f}; border-radius: 3px; min-height: 30px; }}
        \\#settingsWindow QScrollBar::add-line:vertical, #settingsWindow QScrollBar::sub-line:vertical {{ height: 0; }}
        \\#settingsWindow QScrollBar::add-page:vertical, #settingsWindow QScrollBar::sub-page:vertical {{ background: none; }}
        \\
    , .{
        .arrow = arrow,
        .bg = bg,
        .fg = fg,
        .field = c.field,
        .accent = c.accent,
        .accent_hover = c.accent.mix(fg, 0.12),
        // Text on the accent: the background on a light accent, white on a dark one.
        .on_accent = if (c.accent.lightness() > 0.6) bg else Rgb{ .r = 255, .g = 255, .b = 255 },
        .sidebar = bg.mix(fg, 0.03),
        .surface = bg.mix(fg, 0.045),
        .line = bg.mix(fg, 0.12),
        .hover = bg.mix(fg, 0.07),
        .selected = bg.mix(c.accent, 0.28),
        .muted = bg.mix(fg, 0.6),
    });
}

// Building the window ---------------------------------------------------------

/// `active_qss` is the style sheet the app is running with; the window takes its colors.
fn build(state: *State, active_qss: []const u8) !void {
    const t = lang.get();
    const window = qt.QWidget.new2();
    window.setObjectName("settingsWindow");
    window.setWindowTitle(t.settings_title);
    const window_icon = icons.load("zenkai");
    defer window_icon.delete();
    window.setWindowIcon(window_icon);
    window.resize(900, 620);
    window.setMinimumSize2(720, 480);
    state.window = window;

    const root = qt.QHBoxLayout.new(window);
    root.setContentsMargins(0, 0, 0, 0);
    root.setSpacing(0);

    const nav = buildSidebar(root);
    state.nav = nav;
    const right = qt.QVBoxLayout.new2();
    right.setSpacing(0);
    root.addLayout2(right, 1);
    state.pages = qt.QStackedWidget.new2();
    right.addWidget2(state.pages, 1);

    var cards: [std.enums.values(Card).len]?qt.QVBoxLayout = @splat(null);
    inline for (comptime std.enums.values(Page)) |page| {
        const name = @field(t, "settings_page_" ++ @tagName(page));
        nav.addItem(name);
        const content = addPage(state.pages, name, @field(t, "settings_page_" ++ @tagName(page) ++ "_hint"));
        // Cards appear in the order their first field is listed.
        inline for (fields) |field| {
            const card_index = @intFromEnum(field.card);
            if (comptime field.card.page() == page) {
                if (cards[card_index] == null) cards[card_index] = addCard(content, text("card_" ++ @tagName(field.card)));
            }
        }
        if (page == .appearance) state.preview = Preview.init(content);
        content.addStretch();
    }
    inline for (fields, 0..) |field, i| {
        const control = makeControl(field);
        state.controls[i] = control;
        const card = cards[@intFromEnum(field.card)].?;
        switch (control) {
            inline else => |widget| _ = addRow(card, text(field.key), text(field.key ++ "_hint"), widget),
        }
    }

    nav.addItem(t.settings_page_plugins);
    const plugin_page = addPage(state.pages, t.settings_page_plugins, t.settings_page_plugins_hint);
    const plugin_card = addCard(plugin_page, t.settings_card_plugins);
    state.plugin_switches = try state.allocator.alloc(qt.QCheckBox, state.installed.len);
    state.plugin_titles = try state.allocator.alloc(qt.QLabel, state.installed.len);
    for (state.installed, state.plugin_switches, state.plugin_titles) |info, *toggle, *title| {
        toggle.* = makeSwitch();
        const hint = if (info.description.len > 0) info.description else t.settings_plugin_no_description;
        title.* = addRow(plugin_card, info.name, hint, toggle.*);
    }
    plugin_page.addStretch();

    const footer = qt.QWidget.new2();
    footer.setObjectName("settingsFooter");
    footer.setAttribute(qt.qnamespace_enums.WidgetAttribute.WA_StyledBackground);
    const footer_row = qt.QHBoxLayout.new(footer);
    footer_row.setContentsMargins(32, 12, 32, 12);
    state.status = qt.QLabel.new3("");
    state.status.setObjectName("settingsStatus");
    footer_row.addWidget2(state.status, 1);
    const restore_button = qt.QPushButton.new3(t.settings_restore_defaults);
    restore_button.setObjectName("settingsButton");
    restore_button.onClicked(onRestoreDefaults);
    footer_row.addWidget(restore_button);
    state.apply_button = qt.QPushButton.new3(t.settings_apply);
    state.apply_button.setObjectName("settingsApply");
    state.apply_button.setEnabled(false);
    state.apply_button.onClicked(onApply);
    footer_row.addWidget(state.apply_button);
    right.addWidget(footer);

    nav.onCurrentRowChanged(onPageChanged);
    nav.setCurrentRow(0);
    window.onCloseEvent(onWindowClose);
    try restyle(state, active_qss);
}

/// Takes the look of `qss` (the app's style sheet: the base sheet followed by a theme):
/// this window's generated style sheet, sidebar icons and the theme swatches all follow it.
fn restyle(state: *State, qss: []const u8) !void {
    g_colors = parseColors(qss);
    const arrow = writeArrow(state.allocator, state.io, g_colors.foreground);
    defer if (arrow) |path| state.allocator.free(path);
    const window_qss = try styleSheet(state.allocator, g_colors, arrow orelse "");
    defer state.allocator.free(window_qss);
    state.window.setStyleSheet(window_qss);

    var hex: [7]u8 = undefined;
    const icon_color = std.fmt.bufPrint(&hex, "{f}", .{g_colors.background.mix(g_colors.foreground, 0.85)}) catch unreachable;
    for (nav_icons, 0..) |svg, row| {
        const icon = action_icons.tinted(state.nav, svg, icon_color) orelse qt.QIcon.new();
        defer icon.delete();
        state.nav.item(@intCast(row)).setIcon(icon);
    }
    addThemeSwatches(state.allocator, state.controls[fieldIndex("theme")].combo);
    for (state.plugin_titles, 0..) |title, index| {
        var buf: [64]u8 = undefined;
        const style = std.fmt.bufPrint(&buf, "color: {f}; font-weight: 600;", .{pluginColor(index, g_colors.background)}) catch continue;
        title.setStyleSheet(style);
    }
    // Switches paint from g_colors, so they need a repaint too.
    state.window.update();
}

fn buildSidebar(root: qt.QHBoxLayout) qt.QListWidget {
    const t = lang.get();
    const sidebar = qt.QWidget.new2();
    sidebar.setObjectName("settingsSidebar");
    sidebar.setAttribute(qt.qnamespace_enums.WidgetAttribute.WA_StyledBackground);
    sidebar.setFixedWidth(220);
    const column = qt.QVBoxLayout.new(sidebar);
    column.setContentsMargins(12, 20, 12, 12);
    column.setSpacing(0);

    const brand = qt.QLabel.new3(t.settings_brand);
    brand.setObjectName("settingsBrand");
    brand.setContentsMargins(10, 0, 0, 0);
    column.addWidget(brand);
    const brand_sub = qt.QLabel.new3(t.settings_brand_sub);
    brand_sub.setObjectName("settingsBrandSub");
    brand_sub.setContentsMargins(10, 0, 0, 0);
    column.addWidget(brand_sub);
    column.addSpacing(18);

    const nav = qt.QListWidget.new2();
    nav.setObjectName("settingsNav");
    const icon_size = qt.QSize.new4(18, 18);
    defer icon_size.delete();
    nav.setIconSize(icon_size);
    column.addWidget2(nav, 1);
    root.addWidget(sidebar);
    return nav;
}

/// Gives every theme in the dropdown a swatch of its background, field and accent colors.
fn addThemeSwatches(allocator: std.mem.Allocator, combo: qt.QComboBox) void {
    const ratio = @max(combo.screen().devicePixelRatio(), 1.0);
    const icon_size = qt.QSize.new4(swatch_width, swatch_height);
    defer icon_size.delete();
    combo.setIconSize(icon_size);
    var index: i32 = 0;
    while (index < combo.count()) : (index += 1) {
        // Index 0 is "Default", which resolves like no theme at all.
        const name = combo.itemText(allocator, index);
        defer allocator.free(name);
        const colors = themeColorsFor(allocator, if (index == 0) null else name);
        const icon = swatch(colors, ratio);
        defer icon.delete();
        combo.setItemIcon(index, icon);
    }
}

const swatch_width = 38;
const swatch_height = 14;

/// Three overlapping dots (background, field, accent), each ringed in this window's field
/// color so dark dots stay visible on a dark dropdown.
fn swatch(colors: Colors, ratio: f64) qt.QIcon {
    const scale = struct {
        fn px(value: f64, r: f64) i32 {
            return @intFromFloat(@round(value * r));
        }
    };
    const pixmap = qt.QPixmap.new2(scale.px(swatch_width, ratio), scale.px(swatch_height, ratio));
    defer pixmap.delete();
    pixmap.setDevicePixelRatio(ratio);
    const transparent = qt.QColor.new15(0, 0, 0, 0);
    defer transparent.delete();
    pixmap.fill1(transparent);

    const painter = qt.QPainter.new();
    defer painter.delete();
    if (painter.begin(pixmap)) {
        painter.setRenderHint(qt.qpainter_enums.RenderHint.Antialiasing);
        painter.setPen3(qt.qnamespace_enums.PenStyle.NoPen);
        const dots = [_]Rgb{ colors.background, colors.field, colors.accent };
        for (dots, 0..) |rgb, i| {
            const x = @as(i32, @intCast(i)) * 12;
            fill(painter, g_colors.field.mix(g_colors.foreground, 0.35));
            painter.drawEllipse3(x, 0, swatch_height, swatch_height);
            fill(painter, rgb);
            painter.drawEllipse3(x + 2, 2, swatch_height - 4, swatch_height - 4);
        }
        _ = painter.end();
    }
    return qt.QIcon.new2(pixmap);
}

/// Adds a scrollable page with a title and description; returns the layout for its cards.
fn addPage(pages: qt.QStackedWidget, title: []const u8, description: []const u8) qt.QVBoxLayout {
    const scroll = qt.QScrollArea.new2();
    scroll.setObjectName("settingsScroll");
    scroll.setWidgetResizable(true);
    scroll.setHorizontalScrollBarPolicy(qt.qnamespace_enums.ScrollBarPolicy.ScrollBarAlwaysOff);
    const page = qt.QWidget.new2();
    page.setObjectName("settingsPage");
    const column = qt.QVBoxLayout.new(page);
    column.setContentsMargins(36, 30, 36, 30);
    column.setSpacing(0);

    const heading = qt.QLabel.new3(title);
    heading.setObjectName("settingsTitle");
    column.addWidget(heading);
    column.addSpacing(4);
    const summary = qt.QLabel.new3(description);
    summary.setObjectName("settingsDescription");
    summary.setWordWrap(true);
    column.addWidget(summary);

    scroll.setWidget(page);
    _ = pages.addWidget(scroll);
    return column;
}

/// Adds a titled card to a page and returns the layout its rows go into.
/// The small upper-case heading above a card or the preview.
fn addSectionTitle(page: qt.QVBoxLayout, title: []const u8) void {
    page.addSpacing(26);
    var upper: [64]u8 = undefined;
    const heading = qt.QLabel.new3(std.ascii.upperString(&upper, title[0..@min(title.len, upper.len)]));
    heading.setObjectName("settingsCardTitle");
    heading.setContentsMargins(4, 0, 0, 0);
    page.addWidget(heading);
    page.addSpacing(8);
}

fn addCard(page: qt.QVBoxLayout, title: []const u8) qt.QVBoxLayout {
    addSectionTitle(page, title);
    const card = qt.QWidget.new2();
    card.setObjectName("settingsCard");
    card.setAttribute(qt.qnamespace_enums.WidgetAttribute.WA_StyledBackground);
    const rows = qt.QVBoxLayout.new(card);
    rows.setContentsMargins(0, 0, 0, 0);
    rows.setSpacing(0);
    page.addWidget(card);
    return rows;
}

/// One card row: title and hint on the left, the control on the right, and a divider above
/// every row but the first.
/// Returns the title label, for rows that style it (plugin names).
fn addRow(card: qt.QVBoxLayout, title: []const u8, hint: []const u8, control: anytype) qt.QLabel {
    if (card.count() > 0) {
        const divider = qt.QWidget.new2();
        divider.setObjectName("settingsDivider");
        divider.setAttribute(qt.qnamespace_enums.WidgetAttribute.WA_StyledBackground);
        divider.setFixedHeight(1);
        card.addWidget(divider);
    }
    const row = qt.QHBoxLayout.new2();
    row.setContentsMargins(18, 14, 18, 14);
    row.setSpacing(24);
    const labels = qt.QVBoxLayout.new2();
    labels.setSpacing(3);
    const heading = qt.QLabel.new3(title);
    heading.setObjectName("settingsRowTitle");
    labels.addWidget(heading);
    const detail = qt.QLabel.new3(hint);
    detail.setObjectName("settingsRowHint");
    detail.setWordWrap(true);
    labels.addWidget(detail);
    row.addLayout2(labels, 1);
    row.addWidget(control);
    card.addLayout(row);
    return heading;
}

fn FieldType(comptime key: []const u8) type {
    return @TypeOf(@field(config.VisualConfig{}, key));
}

fn makeControl(comptime field: Field) Control {
    const T = FieldType(field.key);
    switch (T) {
        bool => return .{ .toggle = makeSwitch() },
        i32, ?i32 => {
            const spin = qt.QSpinBox.new2();
            spin.setFixedWidth(input_width);
            spin.setRange(field.min, field.max);
            spin.setSuffix(field.suffix);
            // The arrows are hidden by width in the style sheet rather than NoButtons, which
            // squeezes the text field to 1px once a style sheet applies. QSS padding doesn't
            // reach the inner field, so its text is inset here.
            spin.lineEdit().setTextMargins(10, 0, 10, 0);
            if (T == ?i32) spin.setSpecialValueText(lang.get().settings_monitor_cursor);
            spin.onValueChanged(onSpinChanged);
            return .{ .spin = spin };
        },
        ?[]const u8 => {
            if (field.choices.len == 0) {
                const line = qt.QLineEdit.new2();
                line.setFixedWidth(input_width);
                line.setPlaceholderText(field.placeholder);
                line.onTextChanged(onTextEdited);
                return .{ .text = line };
            }
            const combo = qt.QComboBox.new2();
            combo.setFixedWidth(input_width);
            combo.addItem(lang.get().settings_default);
            for (field.choices) |choice| combo.addItem(choice);
            combo.onCurrentIndexChanged(onComboChanged);
            return .{ .combo = combo };
        },
        else => @compileError("no settings control for " ++ field.key),
    }
}

// Preview ----------------------------------------------------------------------

/// A picture of the launcher with the Appearance values as they are set in the window.
/// `launcher` is a stand-in built from the same object names the real launcher uses
/// (mainWindow, searchbarInput, appList, bottomBar, ...), so the selected theme's style
/// sheet applies to it as it would to the launcher. It is laid out off screen at its real
/// size, grabbed, and shown on the page with its size underneath.
const Preview = struct {
    launcher: qt.QWidget,
    layout: qt.QVBoxLayout,
    list: qt.QListWidget,
    image: qt.QLabel,
    caption: qt.QLabel,

    // The largest the picture is drawn: the default 600 by 500 launcher fits at its real
    // size in the page's width; bigger launchers are scaled down to fit.
    const max_width = 600;
    const max_height = 520;

    const sample_apps = [_][2][]const u8{
        .{ "Firefox", "firefox" },
        .{ "Files", "system-file-manager" },
        .{ "Terminal", "utilities-terminal" },
        .{ "Text Editor", "accessories-text-editor" },
        .{ "Calculator", "accessories-calculator" },
        .{ "System Settings", "preferences-system" },
        .{ "Image Viewer", "image-viewer" },
        .{ "Music", "multimedia-player" },
    };

    /// Adds the preview's heading, picture and caption to the end of `page`.
    fn init(page: qt.QVBoxLayout) Preview {
        const t = lang.get();
        const launcher = qt.QWidget.new2();
        launcher.setObjectName("mainWindow");
        launcher.setAttribute(qt.qnamespace_enums.WidgetAttribute.WA_DontShowOnScreen);
        const layout = qt.QVBoxLayout.new(launcher);

        const search = qt.QLineEdit.new2();
        search.setObjectName("searchbarInput");
        search.setPlaceholderText(t.search_placeholder);
        layout.addWidget(search);

        const list = qt.QListWidget.new2();
        list.setObjectName("appList");
        list.setHorizontalScrollBarPolicy(qt.qnamespace_enums.ScrollBarPolicy.ScrollBarAlwaysOff);
        for (sample_apps) |app| {
            const icon = icons.load(app[1]);
            defer icon.delete();
            list.addItem2(qt.QListWidgetItem.new3(icon, app[0]));
        }
        list.setCurrentRow(0);
        layout.addWidget2(list, 1);

        const bottom = qt.QWidget.new2();
        bottom.setObjectName("bottomBar");
        bottom.setFixedHeight(44);
        const bottom_row = qt.QHBoxLayout.new(bottom);
        bottom_row.setContentsMargins(8, 6, 8, 6);
        addBottomAction(bottom_row, t.bottom_bar_open, t.bottom_bar_return);
        bottom_row.addStretch();
        addBottomAction(bottom_row, t.bottom_bar_actions, "Ctrl+K");
        layout.addWidget(bottom);

        addSectionTitle(page, t.settings_card_preview);
        // Framed by a thin border (#settingsPreview) so it reads as a window even when the
        // theme's background matches the page.
        const image = qt.QLabel.new3("");
        image.setObjectName("settingsPreview");
        page.addWidget3(image, 0, qt.qnamespace_enums.AlignmentFlag.AlignHCenter);
        page.addSpacing(8);
        const caption = qt.QLabel.new3("");
        caption.setObjectName("settingsRowHint");
        caption.setAlignment(qt.qnamespace_enums.AlignmentFlag.AlignCenter);
        page.addWidget(caption);

        return .{ .launcher = launcher, .layout = layout, .list = list, .image = image, .caption = caption };
    }

    fn addBottomAction(row: qt.QHBoxLayout, name: []const u8, shortcut: []const u8) void {
        const item = qt.QWidget.new2();
        item.setObjectName("actionItem");
        const item_row = qt.QHBoxLayout.new(item);
        item_row.setContentsMargins(0, 0, 0, 0);
        item_row.setSpacing(6);
        const button = qt.QToolButton.new2();
        button.setObjectName("actionButton");
        button.setText(name);
        item_row.addWidget(button);
        const label = qt.QLabel.new3(shortcut);
        label.setObjectName("actionShortcut");
        item_row.addWidget(label);
        row.addWidget(item);
    }

    fn deinit(self: Preview) void {
        // The launcher stand-in has no parent, so it isn't deleted with the window.
        self.launcher.delete();
    }

    /// Redraws the picture from the window's current Appearance values.
    fn refresh(self: Preview, state: *State) void {
        const allocator = state.allocator;
        const value = struct {
            fn of(s: *State, comptime key: []const u8) i32 {
                return s.controls[fieldIndex(key)].spin.value();
            }
        };
        const width = value.of(state, "window_width");
        const height = value.of(state, "window_height");
        const margin = value.of(state, "layout_margin");
        const icon_extent = value.of(state, "icon_size");

        const qss = selectedStyleSheet(state) catch return;
        defer allocator.free(qss);
        self.launcher.setStyleSheet(qss);

        self.layout.setContentsMargins(margin, margin, margin, margin);
        self.layout.setSpacing(value.of(state, "layout_spacing"));
        const icon_size = qt.QSize.new4(icon_extent, icon_extent);
        defer icon_size.delete();
        self.list.setIconSize(icon_size);
        self.launcher.setFixedSize2(width, height);
        self.launcher.show();
        _ = self.layout.activate();

        // Scale in physical pixels and keep the ratio, so the picture stays sharp on HiDPI.
        const shot = self.launcher.grab();
        defer shot.delete();
        const ratio = shot.devicePixelRatio();
        const physical = struct {
            fn px(logical: i32, r: f64) i32 {
                return @intFromFloat(@round(@as(f64, @floatFromInt(logical)) * r));
            }
        };
        const scaled = shot.scaled4(physical.px(@min(width, max_width), ratio), physical.px(@min(height, max_height), ratio), qt.qnamespace_enums.AspectRatioMode.KeepAspectRatio, qt.qnamespace_enums.TransformationMode.SmoothTransformation);
        defer scaled.delete();
        scaled.setDevicePixelRatio(ratio);
        self.image.setPixmap(scaled);
        // Hug the picture so the border frames it; 1px of border on each side.
        const logical = struct {
            fn px(physical_px: i32, r: f64) i32 {
                return @intFromFloat(@round(@as(f64, @floatFromInt(physical_px)) / r));
            }
        };
        self.image.setFixedSize2(logical.px(scaled.width(), ratio) + 2, logical.px(scaled.height(), ratio) + 2);

        var buf: [64]u8 = undefined;
        self.caption.setText(std.fmt.bufPrint(&buf, "{d} \u{00d7} {d} px", .{ width, height }) catch "");
    }
};

/// The style sheet the launcher would run with for the theme chosen in the window: the base
/// sheet followed by the theme's, as theme_handler.apply combines them. Caller frees.
fn selectedStyleSheet(state: *State) ![]u8 {
    const allocator = state.allocator;
    const combo = state.controls[fieldIndex("theme")].combo;
    const name = if (combo.currentIndex() == 0) null else combo.currentText(allocator);
    defer if (name) |n| allocator.free(n);
    const resolved = if (name != null and std.mem.eql(u8, name.?, "native"))
        theme.resolveNative(allocator)
    else
        theme.resolve(allocator, name);
    defer if (resolved.allocation) |memory| allocator.free(memory);
    return std.mem.concat(allocator, u8, &.{ theme.main_qss, resolved.qss });
}

// Switches ---------------------------------------------------------------------

/// A checkbox painted as a pill switch in the theme's accent color.
fn makeSwitch() qt.QCheckBox {
    const toggle = qt.QCheckBox.new2();
    const size = qt.QSize.new4(42, 24);
    defer size.delete();
    toggle.setFixedSize(size);
    const cursor = qt.QCursor.new2(qt.qnamespace_enums.CursorShape.PointingHandCursor);
    defer cursor.delete();
    toggle.setCursor(cursor);
    toggle.onPaintEvent(paintSwitch);
    toggle.onHitButton(hitSwitch);
    toggle.onToggled(onSwitchToggled);
    return toggle;
}

fn paintSwitch(toggle: qt.QCheckBox, _: qt.QPaintEvent) callconv(.c) void {
    const painter = qt.QPainter.new2(toggle);
    defer painter.delete();
    painter.setRenderHint(qt.qpainter_enums.RenderHint.Antialiasing);
    painter.setPen3(qt.qnamespace_enums.PenStyle.NoPen);

    // On is a filled accent track; off is an empty outlined track with a dimmer knob, so the
    // two read differently even when a theme's accent is a muted grey.
    const width = toggle.width();
    const height = toggle.height();
    const on = toggle.isChecked();
    const radius: f64 = @floatFromInt(@divTrunc(height, 2));
    if (on) {
        fill(painter, g_colors.accent);
        painter.drawRoundedRect2(0, 0, width, height, radius, radius);
    } else {
        const border = 2;
        fill(painter, g_colors.background.mix(g_colors.foreground, 0.35));
        painter.drawRoundedRect2(0, 0, width, height, radius, radius);
        fill(painter, g_colors.background.mix(g_colors.foreground, 0.04));
        painter.drawRoundedRect2(border, border, width - 2 * border, height - 2 * border, radius - border, radius - border);
    }

    const inset = 4;
    const knob = height - 2 * inset;
    // White on a dark or saturated accent; the window background on a very light one.
    const knob_on: Rgb = if (g_colors.accent.lightness() > 0.75) g_colors.background else .{ .r = 255, .g = 255, .b = 255 };
    fill(painter, if (on) knob_on else g_colors.background.mix(g_colors.foreground, 0.55));
    painter.drawEllipse3(if (on) width - knob - inset else inset, inset, knob, knob);
    _ = painter.end();
}

fn fill(painter: qt.QPainter, rgb: Rgb) void {
    const color = rgb.qcolor();
    defer color.delete();
    const brush = qt.QBrush.new3(color);
    defer brush.delete();
    painter.setBrush(brush);
}

// The whole switch is clickable, not only the area a checkbox would draw its box in.
fn hitSwitch(_: qt.QCheckBox, _: qt.QPoint) callconv(.c) bool {
    return true;
}

// Values ----------------------------------------------------------------------

fn showValues(state: *State, cfg: config.VisualConfig) void {
    state.loading = true;
    defer state.loading = false;
    inline for (fields, 0..) |field, i| {
        const value = @field(cfg, field.key);
        const control = state.controls[i];
        switch (FieldType(field.key)) {
            bool => control.toggle.setChecked(value),
            i32 => control.spin.setValue(value),
            ?i32 => control.spin.setValue(value orelse field.min),
            ?[]const u8 => if (field.choices.len == 0)
                control.text.setText(value orelse "")
            else
                selectChoice(control.combo, value orelse ""),
            else => unreachable,
        }
    }
    for (state.installed, state.plugin_switches) |info, toggle| {
        toggle.setChecked(!containsName(cfg.disabled_plugins, info.name));
    }
    state.preview.refresh(state);
}

/// Index 0 is "Default". A value the list doesn't know (say, a custom theme) is added so
/// saving keeps it.
fn selectChoice(combo: qt.QComboBox, value: []const u8) void {
    var index = if (value.len == 0) 0 else combo.findText(value);
    if (index < 0) {
        combo.addItem(value);
        index = combo.count() - 1;
    }
    combo.setCurrentIndex(index);
}

/// The window's current values as config assignments. Strings live in `arena`.
fn collect(state: *State, arena: std.mem.Allocator) ![]config.Assignment {
    var out: std.ArrayList(config.Assignment) = .empty;
    inline for (fields, 0..) |field, i| {
        const control = state.controls[i];
        const value: ?[]const u8 = switch (FieldType(field.key)) {
            bool => if (control.toggle.isChecked()) "true" else "false",
            i32 => try std.fmt.allocPrint(arena, "{d}", .{control.spin.value()}),
            ?i32 => if (control.spin.value() == field.min) null else try std.fmt.allocPrint(arena, "{d}", .{control.spin.value()}),
            ?[]const u8 => if (field.choices.len == 0)
                try quoted(arena, std.mem.trim(u8, control.text.text(arena), " \t"))
            else if (control.combo.currentIndex() == 0)
                null
            else
                try quoted(arena, control.combo.currentText(arena)),
            else => unreachable,
        };
        try out.append(arena, .{ .key = field.key, .value = value });
    }
    try out.append(arena, .{ .key = "disabled_plugins", .value = try disabledPlugins(state, arena) });
    return out.items;
}

fn quoted(arena: std.mem.Allocator, value: []const u8) !?[]const u8 {
    if (value.len == 0) return null;
    return try std.fmt.allocPrint(arena, "\"{s}\"", .{value});
}

/// Plugins switched off plus disabled names that aren't installed, as a quoted list, or null.
fn disabledPlugins(state: *State, arena: std.mem.Allocator) !?[]const u8 {
    var names: std.ArrayList(u8) = .empty;
    for (state.installed, state.plugin_switches) |info, toggle| {
        if (!toggle.isChecked()) try appendName(arena, &names, info.name);
    }
    for (state.disabled) |name| {
        if (!isInstalled(state.installed, name)) try appendName(arena, &names, name);
    }
    return quoted(arena, names.items);
}

fn appendName(arena: std.mem.Allocator, names: *std.ArrayList(u8), name: []const u8) !void {
    if (names.items.len > 0) try names.appendSlice(arena, ", ");
    try names.appendSlice(arena, name);
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn isInstalled(installed: []const plugins.PluginInfo, name: []const u8) bool {
    for (installed) |info| {
        if (std.mem.eql(u8, info.name, name)) return true;
    }
    return false;
}

// Saving ----------------------------------------------------------------------

fn save(state: *State) !void {
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const assignments = try collect(state, arena.allocator());
    try config.saveConfig(state.io, state.allocator, state.path, assignments);
}

/// Saves the window's values and shows the chosen theme on the app and this window.
fn apply(state: *State) !void {
    try save(state);
    setDirty(state, false);
    state.status.setText(lang.get().settings_saved);
    const qss = try selectedStyleSheet(state);
    defer state.allocator.free(qss);
    state.app.setStyleSheet(qss);
    try restyle(state, qss);
}

/// Applies, reporting a failure in the status line. Returns whether it worked.
fn applyAndReport(state: *State) bool {
    apply(state) catch |err| {
        log.info("settings: applying to {s} failed: {}", .{ state.path, err });
        const message = std.fmt.allocPrint(state.allocator, "{s}: {s}", .{ lang.get().settings_save_failed, @errorName(err) }) catch return false;
        defer state.allocator.free(message);
        state.status.setText(message);
        return false;
    };
    return true;
}

fn setDirty(state: *State, dirty: bool) void {
    state.dirty = dirty;
    state.apply_button.setEnabled(dirty);
    if (dirty) state.status.setText(lang.get().settings_unapplied);
}

fn changed() void {
    const state = g_state orelse return;
    // showValues refreshes the preview once when it's done filling in values.
    if (state.loading) return;
    state.preview.refresh(state);
    setDirty(state, true);
}

fn onApply(_: qt.QPushButton) callconv(.c) void {
    const state = g_state orelse return;
    _ = applyAndReport(state);
}

/// Closing with unapplied changes asks whether to apply them first.
fn onWindowClose(_: qt.QWidget, event: qt.QCloseEvent) callconv(.c) void {
    const state = g_state orelse return;
    if (!state.dirty) return;
    const buttons = qt.qmessagebox_enums.StandardButton;
    const answer = qt.QMessageBox.question5(state.window, lang.get().settings_title, lang.get().settings_close_unapplied, buttons.Apply | buttons.Discard | buttons.Cancel, buttons.Apply);
    if (answer == buttons.Cancel or (answer == buttons.Apply and !applyAndReport(state))) event.ignore();
}

fn onSwitchToggled(_: qt.QCheckBox, _: bool) callconv(.c) void {
    changed();
}

fn onSpinChanged(_: qt.QSpinBox, _: i32) callconv(.c) void {
    changed();
}

fn onComboChanged(_: qt.QComboBox, _: i32) callconv(.c) void {
    changed();
}

fn onTextEdited(_: qt.QLineEdit, _: [*:0]const u8) callconv(.c) void {
    changed();
}

/// Fills in the defaults (every plugin on); nothing is written until Apply.
fn onRestoreDefaults(_: qt.QPushButton) callconv(.c) void {
    const state = g_state orelse return;
    showValues(state, .{});
    setDirty(state, true);
}

fn onPageChanged(_: qt.QListWidget, row: i32) callconv(.c) void {
    const state = g_state orelse return;
    state.pages.setCurrentIndex(row);
}

// Tests -----------------------------------------------------------------------

fn fieldIndex(comptime key: []const u8) usize {
    inline for (fields, 0..) |field, i| {
        if (comptime std.mem.eql(u8, field.key, key)) return i;
    }
    @compileError("no settings field " ++ key);
}

test "settings window shows the saved config and applies changes" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var argc: i32 = 1;
    var arg = "zenkai".*;
    var argv = [_][:0]u8{&arg};
    const app = qt.QApplication.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    const dracula = theme.resolve(a, "dracula");
    defer if (dracula.allocation) |m| a.free(m);
    app.setStyleSheet(dracula.qss);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "zenkai.conf", .data =
        \\# my config
        \\theme = "dracula"
        \\icon_size = 40
        \\close_on_focus_out = true
        \\monitor = 1
        \\clipboard = "wl-copy"
        \\disabled_plugins = "emoji, gone"
        \\
    });
    const path = try tmp.dir.realPathFileAlloc(io, "zenkai.conf", a);
    defer a.free(path);
    var cfg = try config.loadConfig(a, path);
    defer cfg.deinit(a);

    var state: State = .{
        .allocator = a,
        .io = io,
        .path = path,
        .app = app,
        .window = undefined,
        .pages = undefined,
        .status = undefined,
        .controls = undefined,
        .plugin_switches = &.{},
        .installed = &.{
            .{ .name = "calculator", .description = "Evaluate math expressions" },
            .{ .name = "emoji", .description = "" },
        },
        .disabled = cfg.disabled_plugins,
    };
    try build(&state, dracula.qss);
    defer destroy(&state);
    showValues(&state, cfg);
    g_state = &state;
    defer g_state = null;
    // Every theme in the dropdown has a swatch.
    const theme_combo = state.controls[fieldIndex("theme")].combo;
    try std.testing.expect(!theme_combo.itemIcon(theme_combo.count() - 1).isNull());

    // The theme's own colors drive the window: Dracula's background and search bar accent.
    try std.testing.expectEqual(Rgb{ .r = 0x28, .g = 0x2a, .b = 0x36 }, g_colors.background);
    try std.testing.expectEqual(Rgb{ .r = 0xff, .g = 0x79, .b = 0xc6 }, g_colors.accent);

    // Filling in values doesn't write; the file still has its original text.
    {
        const before = try tmp.dir.readFileAlloc(io, "zenkai.conf", a, .unlimited);
        defer a.free(before);
        try std.testing.expect(std.mem.indexOf(u8, before, "icon_size = 40") != null);
    }

    // The preview follows the window's values.
    {
        const caption = state.preview.caption.text(a);
        defer a.free(caption);
        try std.testing.expectEqualStrings("600 \u{00d7} 500 px", caption);
    }
    state.controls[fieldIndex("window_width")].spin.setValue(800);
    {
        const caption = state.preview.caption.text(a);
        defer a.free(caption);
        try std.testing.expectEqualStrings("800 \u{00d7} 500 px", caption);
    }
    state.controls[fieldIndex("window_width")].spin.setValue(600);

    // Edits mark the window as changed but write nothing until Apply.
    try std.testing.expect(state.dirty);
    state.controls[fieldIndex("icon_size")].spin.setValue(64);
    try std.testing.expect(state.dirty and state.apply_button.isEnabled());
    {
        const before = try tmp.dir.readFileAlloc(io, "zenkai.conf", a, .unlimited);
        defer a.free(before);
        try std.testing.expect(std.mem.indexOf(u8, before, "icon_size = 40") != null);
    }

    // Apply writes them, keeping other values, the comment and the uninstalled "gone".
    try apply(&state);
    try std.testing.expect(!state.dirty and !state.apply_button.isEnabled());
    {
        var saved = try config.loadConfig(a, path);
        defer saved.deinit(a);
        try std.testing.expectEqual(@as(i32, 64), saved.icon_size);
        try std.testing.expectEqualStrings("dracula", saved.theme.?);
        try std.testing.expect(saved.close_on_focus_out);
        try std.testing.expectEqual(@as(?i32, 1), saved.monitor);
        try std.testing.expectEqualStrings("wl-copy", saved.clipboard.?);
        try std.testing.expectEqual(@as(usize, 2), saved.disabled_plugins.len);
        try std.testing.expectEqualStrings("emoji", saved.disabled_plugins[0]);
        try std.testing.expectEqualStrings("gone", saved.disabled_plugins[1]);
        const saved_text = try tmp.dir.readFileAlloc(io, "zenkai.conf", a, .unlimited);
        defer a.free(saved_text);
        try std.testing.expect(std.mem.startsWith(u8, saved_text, "# my config\n"));
    }

    // Applying a new theme also restyles the app and this window.
    const theme_choice = state.controls[fieldIndex("theme")].combo;
    theme_choice.setCurrentIndex(theme_choice.findText("nord"));
    state.controls[fieldIndex("monitor")].spin.setValue(-1);
    state.controls[fieldIndex("close_on_focus_out")].toggle.setChecked(false);
    state.controls[fieldIndex("clipboard")].text.setText("  ");
    state.plugin_switches[1].setChecked(true);
    try apply(&state);
    {
        var saved = try config.loadConfig(a, path);
        defer saved.deinit(a);
        try std.testing.expectEqualStrings("nord", saved.theme.?);
        try std.testing.expect(saved.monitor == null and saved.clipboard == null);
        try std.testing.expect(!saved.close_on_focus_out);
        try std.testing.expectEqual(@as(usize, 1), saved.disabled_plugins.len);
        try std.testing.expectEqualStrings("gone", saved.disabled_plugins[0]);
    }
    try std.testing.expectEqual(Rgb{ .r = 0x2e, .g = 0x34, .b = 0x40 }, g_colors.background);
    {
        const app_qss = app.styleSheet(a);
        defer a.free(app_qss);
        try std.testing.expect(std.mem.indexOf(u8, app_qss, "#2e3440") != null);
    }

    if (std.c.getenv("ZENKAI_SETTINGS_SHOT")) |prefix| {
        showValues(&state, cfg);
        state.window.show();
        for (0..std.enums.values(Page).len + 1) |page| {
            state.pages.setCurrentIndex(@intCast(page));
            qt.QApplication.processEvents();
            const shot = state.window.grab();
            defer shot.delete();
            const out = try std.fmt.allocPrintSentinel(a, "{s}-{d}.png", .{ std.mem.span(prefix), page }, 0);
            defer a.free(out);
            try std.testing.expect(shot.save(out));
        }
        // The preview sits below the fold, so the whole Appearance page is captured too.
        state.window.resize(900, 1500);
        state.pages.setCurrentIndex(0);
        qt.QApplication.processEvents();
        const page_shot = state.window.grab();
        defer page_shot.delete();
        const page_out = try std.fmt.allocPrintSentinel(a, "{s}-appearance.png", .{std.mem.span(prefix)}, 0);
        defer a.free(page_out);
        try std.testing.expect(page_shot.save(page_out));
    }

    // Restore Defaults fills in the defaults as unapplied edits; applying them gives a
    // config that loads as the defaults.
    onRestoreDefaults(state.apply_button);
    try std.testing.expect(state.dirty);
    try apply(&state);
    var defaults = try config.loadConfig(a, path);
    defer defaults.deinit(a);
    inline for (fields) |field| {
        const expected = @field(config.VisualConfig{}, field.key);
        const actual = @field(defaults, field.key);
        switch (FieldType(field.key)) {
            ?[]const u8 => try std.testing.expect(actual == null),
            else => try std.testing.expectEqual(expected, actual),
        }
    }
    try std.testing.expectEqual(@as(usize, 1), defaults.disabled_plugins.len); // "gone" isn't installed
}

test "plugin names get distinct colors, readable on every theme" {
    // Twelve bundled plugins: every pair of hues stays at least 20 degrees apart.
    const count = 12;
    for (0..count) |a| {
        for (a + 1..count) |b| {
            const apart = @abs(pluginHue(a) - pluginHue(b));
            try std.testing.expect(@min(apart, 360 - apart) >= 20);
        }
    }
    for (theme.theme_entries) |entry| {
        const background = themeColorsFor(std.testing.allocator, entry.name).background;
        for (0..count) |index| {
            const ratio = pluginColor(index, background).contrast(background);
            if (ratio < 4.5) {
                std.debug.print("plugin {d} on theme '{s}' has contrast {d:.2}\n", .{ index, entry.name, ratio });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "theme colors come from the style sheet, with the most saturated accent" {
    // The default dark theme's accent is its focused search bar border, not the grey selection.
    const dark = theme.resolve(std.testing.allocator, "dark");
    defer if (dark.allocation) |m| std.testing.allocator.free(m);
    const colors = parseColors(dark.qss);
    try std.testing.expectEqual(Rgb{ .r = 0x1a, .g = 0x1b, .b = 0x1e }, colors.background);
    try std.testing.expectEqual(Rgb{ .r = 0x31, .g = 0x32, .b = 0x44 }, colors.field);
    try std.testing.expectEqual(Rgb{ .r = 0x89, .g = 0xb4, .b = 0xfa }, colors.accent);

    // Ember starts with a credit comment; its colors still parse, with the amber accent.
    const ember = theme.resolve(std.testing.allocator, "ember");
    defer if (ember.allocation) |m| std.testing.allocator.free(m);
    const ember_colors = parseColors(ember.qss);
    try std.testing.expectEqual(Rgb{ .r = 0x14, .g = 0x13, .b = 0x12 }, ember_colors.background);
    try std.testing.expectEqual(Rgb{ .r = 0xfe, .g = 0x80, .b = 0x19 }, ember_colors.accent);

    // Selector lists match, later rules win, comments are skipped, and "color" doesn't match
    // "border-color" or "selection-color".
    const qss =
        \\/* base */ QWidget { color: #111; }
        \\QLabel, QWidget { border-color: #f00; selection-color: #0f0; color: #abc; }
        \\QWidget#other { color: #fff; }
        \\QWidget { color: palette(text); }
    ;
    try std.testing.expectEqual(Rgb{ .r = 0xaa, .g = 0xbb, .b = 0xcc }, ruleColor(qss, "QWidget", "color").?);
    try std.testing.expect(ruleColor(qss, "QWidget", "background-color") == null);
    try std.testing.expect(Rgb.parse("#12345") == null and Rgb.parse("red") == null);
}

test "easing choices are exactly the names the animation parser accepts" {
    for (EasingType.names) |name| {
        const parsed = EasingType.fromName(name);
        try std.testing.expect(parsed != .OutCubic or std.mem.eql(u8, name, "out-cubic"));
    }
    try std.testing.expectEqual(@as(usize, std.enums.values(EasingType).len), EasingType.names.len);
}
