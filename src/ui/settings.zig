//! The settings window (`zenkai --settings`). It edits the config file zenkai reads at
//! startup, so saved changes apply the next time the launcher opens.

const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");
const plugins = @import("plugins");
const lang = @import("lang");
const log = @import("utils").log;
const theme = @import("../theme/theme.zig");
const EasingType = @import("animation.zig").EasingType;

const Page = enum { appearance, behaviour, animations, integrations };

/// One editable config key; `key` is both the VisualConfig field and the config file key.
/// The control follows the field's type: bool is a checkbox, i32 a spin box, ?i32 a spin box
/// whose lowest value means "not set", and ?[]const u8 a dropdown when `choices` is given,
/// otherwise a text field. Leaving a dropdown or text field empty removes the key.
const Field = struct {
    key: []const u8,
    page: Page,
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

const fields = [_]Field{
    .{ .key = "theme", .page = .appearance, .choices = &theme_names },
    .{ .key = "icon_size", .page = .appearance, .min = 16, .max = 128, .suffix = " px" },
    .{ .key = "window_width", .page = .appearance, .min = 300, .max = 4000, .suffix = " px" },
    .{ .key = "window_height", .page = .appearance, .min = 200, .max = 3000, .suffix = " px" },
    .{ .key = "layout_margin", .page = .appearance, .max = 64, .suffix = " px" },
    .{ .key = "layout_spacing", .page = .appearance, .max = 64, .suffix = " px" },
    .{ .key = "close_on_focus_out", .page = .behaviour },
    .{ .key = "show_backdrop", .page = .behaviour },
    .{ .key = "file_previews", .page = .behaviour },
    .{ .key = "fullscreen", .page = .behaviour },
    .{ .key = "monitor", .page = .behaviour, .min = -1, .max = 15 },
    .{ .key = "no_animations", .page = .animations },
    .{ .key = "animation_interval", .page = .animations, .max = 2000, .suffix = " ms" },
    .{ .key = "animation_easing", .page = .animations, .choices = &EasingType.names },
    .{ .key = "clipboard", .page = .integrations, .placeholder = "wl-copy" },
    .{ .key = "url_handler", .page = .integrations, .placeholder = "xdg-open" },
};

const Control = union(enum) {
    check: qt.QCheckBox,
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
    plugin_list: qt.QListWidget,
    installed: []const plugins.PluginInfo,
    // Disabled names with no installed plugin, kept so saving doesn't silently drop them.
    disabled: []const []const u8,
};

// Qt callbacks carry no user data, so they reach the open window through this.
var g_state: ?*State = null;

fn label(comptime key: []const u8) []const u8 {
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

    var state: State = undefined;
    state.allocator = allocator;
    state.io = io;
    state.path = path;
    state.installed = installed;
    state.disabled = cfg.disabled_plugins;
    build(&state);
    defer state.window.delete();
    showValues(&state, cfg);

    g_state = &state;
    defer g_state = null;
    state.window.show();
    _ = qt.QApplication.exec();
}

fn build(state: *State) void {
    const t = lang.get();
    const window = qt.QWidget.new2();
    window.setWindowTitle(t.settings_title);
    window.setObjectName("settingsWindow");
    window.resize(760, 520);
    state.window = window;

    const outer = qt.QVBoxLayout.new(window);
    const body = qt.QHBoxLayout.new2();
    outer.addLayout(body);

    const sidebar = qt.QListWidget.new2();
    sidebar.setObjectName("settingsSidebar");
    sidebar.setFixedWidth(180);
    body.addWidget(sidebar);
    state.pages = qt.QStackedWidget.new2();
    body.addWidget(state.pages);

    var forms: [std.enums.values(Page).len]qt.QFormLayout = undefined;
    inline for (comptime std.enums.values(Page), 0..) |page, i| {
        const name = @field(t, "settings_page_" ++ @tagName(page));
        sidebar.addItem(name);
        const content = addPage(state.pages, name);
        forms[i] = qt.QFormLayout.new2();
        content.addLayout(forms[i]);
        content.addStretch();
    }
    inline for (fields, 0..) |field, i| {
        const control = makeControl(field);
        state.controls[i] = control;
        const form = forms[@intFromEnum(field.page)];
        switch (control) {
            .check => |check| form.addRow5(check),
            inline else => |widget| form.addRow3(label(field.key), widget),
        }
    }

    sidebar.addItem(t.settings_page_plugins);
    const plugin_page = addPage(state.pages, t.settings_page_plugins);
    const hint = qt.QLabel.new3(t.settings_plugins_hint);
    hint.setWordWrap(true);
    plugin_page.addWidget(hint);
    state.plugin_list = qt.QListWidget.new2();
    for (state.installed) |info| {
        const text = std.fmt.allocPrint(state.allocator, "{s} — {s}", .{ info.name, info.description }) catch continue;
        defer state.allocator.free(text);
        const item = qt.QListWidgetItem.new2(if (info.description.len > 0) text else info.name);
        item.setFlags(qt.qnamespace_enums.ItemFlag.ItemIsUserCheckable | qt.qnamespace_enums.ItemFlag.ItemIsEnabled);
        state.plugin_list.addItem2(item);
    }
    plugin_page.addWidget(state.plugin_list);

    const buttons = qt.QHBoxLayout.new2();
    outer.addLayout(buttons);
    const restore_button = qt.QPushButton.new3(t.settings_restore_defaults);
    restore_button.onClicked(onRestoreDefaults);
    buttons.addWidget(restore_button);
    state.status = qt.QLabel.new3("");
    buttons.addWidget(state.status);
    buttons.addStretch();
    const close_button = qt.QPushButton.new3(t.settings_close);
    close_button.onClicked(onClose);
    buttons.addWidget(close_button);
    const save_button = qt.QPushButton.new3(t.settings_save);
    save_button.setDefault(true);
    save_button.onClicked(onSave);
    buttons.addWidget(save_button);

    sidebar.onCurrentRowChanged(onPageChanged);
    sidebar.setCurrentRow(0);
}

/// Adds a page with a heading and returns its layout for the page's contents.
fn addPage(pages: qt.QStackedWidget, title: []const u8) qt.QVBoxLayout {
    const page = qt.QWidget.new2();
    const layout = qt.QVBoxLayout.new(page);
    const heading = qt.QLabel.new3(title);
    heading.setStyleSheet("font-size: 18px; font-weight: 600;");
    layout.addWidget(heading);
    _ = pages.addWidget(page);
    return layout;
}

fn FieldType(comptime key: []const u8) type {
    return @TypeOf(@field(config.VisualConfig{}, key));
}

fn makeControl(comptime field: Field) Control {
    const T = FieldType(field.key);
    switch (T) {
        bool => return .{ .check = qt.QCheckBox.new3(label(field.key)) },
        i32, ?i32 => {
            const spin = qt.QSpinBox.new2();
            spin.setRange(field.min, field.max);
            spin.setSuffix(field.suffix);
            if (T == ?i32) spin.setSpecialValueText(lang.get().settings_monitor_cursor);
            return .{ .spin = spin };
        },
        ?[]const u8 => {
            if (field.choices.len == 0) {
                const text = qt.QLineEdit.new2();
                text.setPlaceholderText(field.placeholder);
                return .{ .text = text };
            }
            const combo = qt.QComboBox.new2();
            combo.addItem(lang.get().settings_default);
            for (field.choices) |choice| combo.addItem(choice);
            return .{ .combo = combo };
        },
        else => @compileError("no settings control for " ++ field.key),
    }
}

fn showValues(state: *State, cfg: config.VisualConfig) void {
    inline for (fields, 0..) |field, i| {
        const value = @field(cfg, field.key);
        const control = state.controls[i];
        switch (FieldType(field.key)) {
            bool => control.check.setChecked(value),
            i32 => control.spin.setValue(value),
            ?i32 => control.spin.setValue(value orelse field.min),
            ?[]const u8 => if (field.choices.len == 0)
                control.text.setText(value orelse "")
            else
                selectChoice(control.combo, value orelse ""),
            else => unreachable,
        }
    }
    for (state.installed, 0..) |info, row| {
        const item = state.plugin_list.item(@intCast(row));
        const enabled = !containsName(cfg.disabled_plugins, info.name);
        item.setCheckState(if (enabled) qt.qnamespace_enums.CheckState.Checked else qt.qnamespace_enums.CheckState.Unchecked);
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
            bool => if (control.check.isChecked()) "true" else "false",
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

fn quoted(arena: std.mem.Allocator, text: []const u8) !?[]const u8 {
    if (text.len == 0) return null;
    return try std.fmt.allocPrint(arena, "\"{s}\"", .{text});
}

/// Unchecked plugins plus disabled names that aren't installed, as a quoted list, or null.
fn disabledPlugins(state: *State, arena: std.mem.Allocator) !?[]const u8 {
    var names: std.ArrayList(u8) = .empty;
    for (state.installed, 0..) |info, row| {
        if (state.plugin_list.item(@intCast(row)).checkState() == qt.qnamespace_enums.CheckState.Checked) continue;
        try appendName(arena, &names, info.name);
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

fn save(state: *State) !void {
    var arena = std.heap.ArenaAllocator.init(state.allocator);
    defer arena.deinit();
    const assignments = try collect(state, arena.allocator());
    try config.saveConfig(state.io, state.allocator, state.path, assignments);
}

fn onSave(_: qt.QPushButton) callconv(.c) void {
    const state = g_state orelse return;
    save(state) catch |err| {
        log.info("settings: saving {s} failed: {}", .{ state.path, err });
        const message = std.fmt.allocPrint(state.allocator, "{s}: {s}", .{ lang.get().settings_save_failed, @errorName(err) }) catch return;
        defer state.allocator.free(message);
        state.status.setText(message);
        return;
    };
    state.status.setText(lang.get().settings_saved);
}

fn onRestoreDefaults(_: qt.QPushButton) callconv(.c) void {
    const state = g_state orelse return;
    // Defaults enable every plugin; nothing is written until Save.
    showValues(state, .{});
    state.status.setText("");
}

fn onClose(_: qt.QPushButton) callconv(.c) void {
    const state = g_state orelse return;
    _ = state.window.close();
}

fn onPageChanged(_: qt.QListWidget, row: i32) callconv(.c) void {
    const state = g_state orelse return;
    state.pages.setCurrentIndex(row);
}

fn fieldIndex(comptime key: []const u8) usize {
    inline for (fields, 0..) |field, i| {
        if (comptime std.mem.eql(u8, field.key, key)) return i;
    }
    @compileError("no settings field " ++ key);
}

test "settings window shows the saved config and saves what it shows" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var argc: i32 = 1;
    var arg = "zenkai".*;
    var argv = [_][:0]u8{&arg};
    const app = qt.QApplication.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();

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

    var state: State = undefined;
    state.allocator = a;
    state.io = io;
    state.path = path;
    state.installed = &.{
        .{ .name = "calculator", .description = "Evaluate math expressions" },
        .{ .name = "emoji", .description = "" },
    };
    state.disabled = cfg.disabled_plugins;
    build(&state);
    defer state.window.delete();
    showValues(&state, cfg);

    // Saving without edits keeps every value, the comment and the uninstalled "gone".
    try save(&state);
    {
        var saved = try config.loadConfig(a, path);
        defer saved.deinit(a);
        try std.testing.expectEqualStrings("dracula", saved.theme.?);
        try std.testing.expectEqual(@as(i32, 40), saved.icon_size);
        try std.testing.expect(saved.close_on_focus_out);
        try std.testing.expectEqual(@as(?i32, 1), saved.monitor);
        try std.testing.expectEqualStrings("wl-copy", saved.clipboard.?);
        try std.testing.expectEqual(@as(usize, 2), saved.disabled_plugins.len);
        try std.testing.expectEqualStrings("emoji", saved.disabled_plugins[0]);
        try std.testing.expectEqualStrings("gone", saved.disabled_plugins[1]);
        const text = try tmp.dir.readFileAlloc(io, "zenkai.conf", a, .unlimited);
        defer a.free(text);
        try std.testing.expect(std.mem.startsWith(u8, text, "# my config\n"));
    }

    // Edits made through the controls are what gets written.
    state.controls[fieldIndex("icon_size")].spin.setValue(64);
    state.controls[fieldIndex("theme")].combo.setCurrentIndex(0);
    state.controls[fieldIndex("monitor")].spin.setValue(-1);
    state.controls[fieldIndex("clipboard")].text.setText("  ");
    state.plugin_list.item(1).setCheckState(qt.qnamespace_enums.CheckState.Checked);
    try save(&state);
    {
        var saved = try config.loadConfig(a, path);
        defer saved.deinit(a);
        try std.testing.expectEqual(@as(i32, 64), saved.icon_size);
        try std.testing.expect(saved.theme == null and saved.monitor == null and saved.clipboard == null);
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

    // Restore Defaults followed by Save gives a config that loads as the defaults.
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
