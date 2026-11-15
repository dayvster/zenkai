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

const page_icons = [_][]const u8{
    "preferences-desktop-theme",
    "preferences-system-windows",
    "preferences-desktop-effects",
    "utilities-terminal",
};
const plugins_icon = "preferences-plugin";

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
    window: qt.QWidget,
    pages: qt.QStackedWidget,
    status: qt.QLabel,
    controls: [fields.len]Control,
    // One switch per installed plugin, in `installed` order.
    plugin_switches: []qt.QCheckBox,
    installed: []const plugins.PluginInfo,
    // Disabled names with no installed plugin, kept so saving doesn't silently drop them.
    disabled: []const []const u8,
    // Set while the window fills in values, so those changes aren't saved back.
    loading: bool = false,
};

// Qt callbacks carry no user data, so they reach the open window through these.
var g_state: ?*State = null;
var g_colors: Colors = .{};

fn text(comptime key: []const u8) []const u8 {
    return @field(lang.get(), "settings_" ++ key);
}

pub fn run(allocator: std.mem.Allocator) !void {
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
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
        .window = undefined,
        .pages = undefined,
        .status = undefined,
        .controls = undefined,
        .plugin_switches = &.{},
        .installed = installed,
        .disabled = cfg.disabled_plugins,
    };
    try build(&state);
    defer destroy(&state);
    showValues(&state, cfg);

    g_state = &state;
    defer g_state = null;
    state.window.show();
    _ = qt.QApplication.exec();
}

fn destroy(state: *State) void {
    state.window.delete();
    state.allocator.free(state.plugin_switches);
}

// Theme colors ----------------------------------------------------------------

const Rgb = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    // `color` is a reference into a palette (QPalette::color returns const QColor&), so it is
    // read, never deleted.
    fn of(color: qt.QColor) Rgb {
        return .{ .r = @intCast(color.red()), .g = @intCast(color.green()), .b = @intCast(color.blue()) };
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

const Colors = struct {
    background: Rgb = .{ .r = 0x20, .g = 0x20, .b = 0x24 },
    foreground: Rgb = .{ .r = 0xee, .g = 0xee, .b = 0xee },
    field: Rgb = .{ .r = 0x2c, .g = 0x2c, .b = 0x32 },
    accent: Rgb = .{ .r = 0x3d, .g = 0x8b, .b = 0xfd },
};

/// Every theme styles the launcher's search bar (`#searchbarInput`) with its background,
/// text and selection color, so a polished stand-in reveals the theme's palette. The
/// palettes are references owned by the widgets, so only the widgets are deleted.
fn themeColors() Colors {
    const window = qt.QWidget.new2();
    defer window.delete();
    window.ensurePolished();
    const window_palette = window.palette();

    const search = qt.QLineEdit.new2();
    defer search.delete();
    search.setObjectName("searchbarInput");
    search.ensurePolished();
    const search_palette = search.palette();

    const role = qt.qpalette_enums.ColorRole;
    return .{
        .background = Rgb.of(window_palette.color2(role.Window)),
        .foreground = Rgb.of(window_palette.color2(role.WindowText)),
        .field = Rgb.of(search_palette.color2(role.Base)),
        .accent = Rgb.of(search_palette.color2(role.Highlight)),
    };
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
        \\#settingsFooter {{ background: {[bg]f}; border-top: 1px solid {[line]f}; }}
        \\#settingsStatus {{ color: {[muted]f}; font-size: 12px; }}
        \\#settingsButton {{ background: transparent; color: {[fg]f}; border: 1px solid {[line]f}; border-radius: 8px; padding: 7px 14px; }}
        \\#settingsButton:hover {{ background: {[hover]f}; }}
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
        .sidebar = bg.mix(fg, 0.03),
        .surface = bg.mix(fg, 0.045),
        .line = bg.mix(fg, 0.12),
        .hover = bg.mix(fg, 0.07),
        .selected = bg.mix(c.accent, 0.28),
        .muted = bg.mix(fg, 0.6),
    });
}

// Building the window ---------------------------------------------------------

fn build(state: *State) !void {
    const t = lang.get();
    g_colors = themeColors();
    const arrow = writeArrow(state.allocator, state.io, g_colors.foreground);
    defer if (arrow) |path| state.allocator.free(path);
    const qss = try styleSheet(state.allocator, g_colors, arrow orelse "");
    defer state.allocator.free(qss);

    const window = qt.QWidget.new2();
    window.setObjectName("settingsWindow");
    window.setWindowTitle(t.settings_title);
    const window_icon = icons.load("zenkai");
    defer window_icon.delete();
    window.setWindowIcon(window_icon);
    window.setStyleSheet(qss);
    window.resize(900, 620);
    window.setMinimumSize2(720, 480);
    state.window = window;

    const root = qt.QHBoxLayout.new(window);
    root.setContentsMargins(0, 0, 0, 0);
    root.setSpacing(0);

    const nav = buildSidebar(root);
    const right = qt.QVBoxLayout.new2();
    right.setSpacing(0);
    root.addLayout2(right, 1);
    state.pages = qt.QStackedWidget.new2();
    right.addWidget2(state.pages, 1);

    var cards: [std.enums.values(Card).len]?qt.QVBoxLayout = @splat(null);
    inline for (comptime std.enums.values(Page), 0..) |page, page_index| {
        const name = @field(t, "settings_page_" ++ @tagName(page));
        addNavItem(nav, page_icons[page_index], name);
        const content = addPage(state.pages, name, @field(t, "settings_page_" ++ @tagName(page) ++ "_hint"));
        // Cards appear in the order their first field is listed.
        inline for (fields) |field| {
            const card_index = @intFromEnum(field.card);
            if (comptime field.card.page() == page) {
                if (cards[card_index] == null) cards[card_index] = addCard(content, text("card_" ++ @tagName(field.card)));
            }
        }
        content.addStretch();
    }
    inline for (fields, 0..) |field, i| {
        const control = makeControl(field);
        state.controls[i] = control;
        const card = cards[@intFromEnum(field.card)].?;
        switch (control) {
            inline else => |widget| addRow(card, text(field.key), text(field.key ++ "_hint"), widget),
        }
    }

    addNavItem(nav, plugins_icon, t.settings_page_plugins);
    const plugin_page = addPage(state.pages, t.settings_page_plugins, t.settings_page_plugins_hint);
    const plugin_card = addCard(plugin_page, t.settings_card_plugins);
    state.plugin_switches = try state.allocator.alloc(qt.QCheckBox, state.installed.len);
    for (state.installed, state.plugin_switches) |info, *toggle| {
        toggle.* = makeSwitch();
        const hint = if (info.description.len > 0) info.description else t.settings_plugin_no_description;
        addRow(plugin_card, info.name, hint, toggle.*);
    }
    plugin_page.addStretch();

    const footer = qt.QWidget.new2();
    footer.setObjectName("settingsFooter");
    footer.setAttribute(qt.qnamespace_enums.WidgetAttribute.WA_StyledBackground);
    const footer_row = qt.QHBoxLayout.new(footer);
    footer_row.setContentsMargins(32, 12, 32, 12);
    state.status = qt.QLabel.new3(t.settings_autosave);
    state.status.setObjectName("settingsStatus");
    footer_row.addWidget2(state.status, 1);
    const restore_button = qt.QPushButton.new3(t.settings_restore_defaults);
    restore_button.setObjectName("settingsButton");
    restore_button.onClicked(onRestoreDefaults);
    footer_row.addWidget(restore_button);
    right.addWidget(footer);

    nav.onCurrentRowChanged(onPageChanged);
    nav.setCurrentRow(0);
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

fn addNavItem(nav: qt.QListWidget, icon_name: []const u8, name: []const u8) void {
    const icon = icons.load(icon_name);
    defer icon.delete();
    nav.addItem2(qt.QListWidgetItem.new3(icon, name));
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
fn addCard(page: qt.QVBoxLayout, title: []const u8) qt.QVBoxLayout {
    page.addSpacing(26);
    var upper: [64]u8 = undefined;
    const heading = qt.QLabel.new3(std.ascii.upperString(&upper, title[0..@min(title.len, upper.len)]));
    heading.setObjectName("settingsCardTitle");
    heading.setContentsMargins(4, 0, 0, 0);
    page.addWidget(heading);
    page.addSpacing(8);

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
fn addRow(card: qt.QVBoxLayout, title: []const u8, hint: []const u8, control: anytype) void {
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
                line.onEditingFinished(onTextEdited);
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

    const width = toggle.width();
    const height = toggle.height();
    const on = toggle.isChecked();
    const track_rgb = if (on) g_colors.accent else g_colors.background.mix(g_colors.foreground, 0.25);
    fill(painter, track_rgb);
    const radius: f64 = @floatFromInt(@divTrunc(height, 2));
    painter.drawRoundedRect2(0, 0, width, height, radius, radius);

    const inset = 3;
    const knob = height - 2 * inset;
    fill(painter, .{ .r = 255, .g = 255, .b = 255 });
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

fn saveAndReport(state: *State) void {
    save(state) catch |err| {
        log.info("settings: saving {s} failed: {}", .{ state.path, err });
        const message = std.fmt.allocPrint(state.allocator, "{s}: {s}", .{ lang.get().settings_save_failed, @errorName(err) }) catch return;
        defer state.allocator.free(message);
        state.status.setText(message);
        return;
    };
    state.status.setText(lang.get().settings_saved);
}

fn changed() void {
    const state = g_state orelse return;
    if (state.loading) return;
    saveAndReport(state);
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

fn onTextEdited(_: qt.QLineEdit) callconv(.c) void {
    changed();
}

fn onRestoreDefaults(_: qt.QPushButton) callconv(.c) void {
    const state = g_state orelse return;
    const buttons = qt.qmessagebox_enums.StandardButton;
    const answer = qt.QMessageBox.question5(state.window, lang.get().settings_restore_defaults, lang.get().settings_restore_confirm, buttons.Yes | buttons.No, buttons.No);
    if (answer != buttons.Yes) return;
    // Defaults turn every plugin on.
    showValues(state, .{});
    saveAndReport(state);
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

test "settings window shows the saved config and saves every change" {
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
    try build(&state);
    defer destroy(&state);
    showValues(&state, cfg);
    g_state = &state;
    defer g_state = null;

    // The theme's own colors drive the window: Dracula's background and search bar accent.
    try std.testing.expectEqual(Rgb{ .r = 0x28, .g = 0x2a, .b = 0x36 }, g_colors.background);
    try std.testing.expectEqual(Rgb{ .r = 0xff, .g = 0x79, .b = 0xc6 }, g_colors.accent);

    // Filling in values doesn't write; the file still has its original text.
    {
        const before = try tmp.dir.readFileAlloc(io, "zenkai.conf", a, .unlimited);
        defer a.free(before);
        try std.testing.expect(std.mem.indexOf(u8, before, "icon_size = 40") != null);
    }

    // Every edit saves on its own, keeping values, the comment and the uninstalled "gone".
    state.controls[fieldIndex("icon_size")].spin.setValue(64);
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

    state.controls[fieldIndex("theme")].combo.setCurrentIndex(0);
    state.controls[fieldIndex("monitor")].spin.setValue(-1);
    state.controls[fieldIndex("close_on_focus_out")].toggle.setChecked(false);
    state.controls[fieldIndex("clipboard")].text.setText("  ");
    state.controls[fieldIndex("clipboard")].text.editingFinished();
    state.plugin_switches[1].setChecked(true);
    {
        var saved = try config.loadConfig(a, path);
        defer saved.deinit(a);
        try std.testing.expect(saved.theme == null and saved.monitor == null and saved.clipboard == null);
        try std.testing.expect(!saved.close_on_focus_out);
        try std.testing.expectEqual(@as(usize, 1), saved.disabled_plugins.len);
        try std.testing.expectEqualStrings("gone", saved.disabled_plugins[0]);
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
    }

    // Restoring the defaults and saving gives a config that loads as the defaults.
    showValues(&state, .{});
    try save(&state);
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

test "easing choices are exactly the names the animation parser accepts" {
    for (EasingType.names) |name| {
        const parsed = EasingType.fromName(name);
        try std.testing.expect(parsed != .OutCubic or std.mem.eql(u8, name, "out-cubic"));
    }
    try std.testing.expectEqual(@as(usize, std.enums.values(EasingType).len), EasingType.names.len);
}
