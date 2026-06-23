const std = @import("std");
const log = @import("utils").log;
const fsutils = @import("utils").fsutils;

pub const dark_qss = @embedFile("../styles/dark.theme.qss");
pub const light_qss = @embedFile("../styles/light.theme.qss");
pub const dracula_qss = @embedFile("../styles/dracula.qss");
pub const ayu_dark_qss = @embedFile("../styles/ayu-dark.qss");
pub const minimal_qss = @embedFile("../styles/minimal.qss");
pub const gruvbox_qss = @embedFile("../styles/gruvbox.qss");
pub const tokyonight_qss = @embedFile("../styles/tokyonight.qss");
pub const catppuccin_qss = @embedFile("../styles/catppuccin.qss");
pub const kanagawa_qss = @embedFile("../styles/kanagawa.qss");
pub const everforest_qss = @embedFile("../styles/everforest.qss");
pub const nord_qss = @embedFile("../styles/nord.qss");
pub const rose_pine_qss = @embedFile("../styles/rose-pine.qss");
pub const solarized_dark_qss = @embedFile("../styles/solarized-dark.qss");
pub const one_dark_qss = @embedFile("../styles/one-dark.qss");
pub const monokai_qss = @embedFile("../styles/monokai.qss");
pub const palenight_qss = @embedFile("../styles/palenight.qss");
pub const synthwave84_qss = @embedFile("../styles/synthwave84.qss");
pub const ubuntu_qss = @embedFile("../styles/ubuntu.qss");
pub const adwaita_qss = @embedFile("../styles/adwaita.qss");
pub const ubuntu_dark_qss = @embedFile("../styles/ubuntu-dark.qss");
pub const adwaita_dark_qss = @embedFile("../styles/adwaita-dark.qss");
pub const cupertino_qss = @embedFile("../styles/cupertino.qss");
pub const cupertino_dark_qss = @embedFile("../styles/cupertino-dark.qss");
pub const matrix_qss = @embedFile("../styles/matrix.qss");
pub const retro_qss = @embedFile("../styles/retro.qss");
pub const win95_qss = @embedFile("../styles/win95.qss");
pub const high_contrast_qss = @embedFile("../styles/high-contrast.qss");
pub const high_contrast_light_qss = @embedFile("../styles/high-contrast-light.qss");
pub const frieza_qss = @embedFile("../styles/frieza.qss");
pub const buu_qss = @embedFile("../styles/buu.qss");
pub const github_dark_qss = @embedFile("../styles/github-dark.qss");
pub const github_light_qss = @embedFile("../styles/github-light.qss");
pub const night_owl_qss = @embedFile("../styles/night-owl.qss");
pub const ayu_mirage_qss = @embedFile("../styles/ayu-mirage.qss");
pub const cobalt_qss = @embedFile("../styles/cobalt.qss");
pub const minimal_light_qss = @embedFile("../styles/minimal-light.qss");
pub const solarized_light_qss = @embedFile("../styles/solarized-light.qss");
pub const one_light_qss = @embedFile("../styles/one-light.qss");
pub const catppuccin_frappe_qss = @embedFile("../styles/catppuccin-frappe.qss");
pub const catppuccin_macchiato_qss = @embedFile("../styles/catppuccin-macchiato.qss");
pub const shades_of_purple_qss = @embedFile("../styles/shades-of-purple.qss");
pub const material_qss = @embedFile("../styles/material.qss");
pub const monokai_pro_qss = @embedFile("../styles/monokai-pro.qss");
pub const breeze_dark_qss = @embedFile("../styles/breeze-dark.qss");
pub const breeze_light_qss = @embedFile("../styles/breeze-light.qss");
pub const catppuccin_latte_qss = @embedFile("../styles/catppuccin-latte.qss");
pub const rose_pine_dawn_qss = @embedFile("../styles/rose-pine-dawn.qss");
pub const tokyo_night_light_qss = @embedFile("../styles/tokyo-night-light.qss");
pub const tokyo_night_storm_qss = @embedFile("../styles/tokyo-night-storm.qss");
pub const tokyo_night_moon_qss = @embedFile("../styles/tokyo-night-moon.qss");
pub const kanagawa_lotus_qss = @embedFile("../styles/kanagawa-lotus.qss");
pub const kanagawa_dragon_qss = @embedFile("../styles/kanagawa-dragon.qss");
pub const poimandres_qss = @embedFile("../styles/poimandres.qss");
pub const arc_dark_qss = @embedFile("../styles/arc-dark.qss");
pub const noctis_qss = @embedFile("../styles/noctis.qss");
pub const sweet_qss = @embedFile("../styles/sweet.qss");
pub const goku_qss = @embedFile("../styles/goku.qss");
pub const gohan_qss = @embedFile("../styles/gohan.qss");
pub const vegeta_qss = @embedFile("../styles/vegeta.qss");
pub const piccolo_qss = @embedFile("../styles/piccolo.qss");
pub const bulma_qss = @embedFile("../styles/bulma.qss");
pub const trunks_qss = @embedFile("../styles/trunks.qss");
pub const tien_qss = @embedFile("../styles/tien.qss");
pub const spacegray_qss = @embedFile("../styles/spacegray.qss");
pub const launchpad_qss = @embedFile("../styles/launchpad.qss");
pub const main_qss = @embedFile("../styles/main.qss");

pub var g_theme_qss_filename: []const u8 = "dark.theme.qss";

const ThemeResult = struct {
    qss: []const u8,
    allocation: ?[]u8,
};

fn readDevStyle(allocator: std.mem.Allocator, filename: []const u8) ?[]u8 {
    const path = std.fs.path.join(allocator, &.{ "src", "styles", filename }) catch return null;
    defer allocator.free(path);
    return fsutils.readFile(allocator, path, 128 * 1024) catch null;
}

fn readThemeFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    const resolved = fsutils.expandTilde(allocator, path) catch return null;
    defer allocator.free(resolved);
    return fsutils.readFile(allocator, resolved, 128 * 1024) catch null;
}

pub fn readMainQss(allocator: std.mem.Allocator) ?[]u8 {
    return readDevStyle(allocator, "main.qss");
}

fn resolveWithDisk(allocator: std.mem.Allocator, name: []const u8, embedded: []const u8) ThemeResult {
    g_theme_qss_filename = name;
    if (readDevStyle(allocator, name)) |content| {
        return .{ .qss = content, .allocation = content };
    }
    return .{ .qss = embedded, .allocation = null };
}

pub fn resolve(allocator: std.mem.Allocator, theme_arg: ?[]const u8) ThemeResult {
    if (theme_arg) |name| {
        if (std.mem.eql(u8, name, "light")) {
            return resolveWithDisk(allocator, "light.theme.qss", light_qss);
        } else if (std.mem.eql(u8, name, "dracula")) {
            return resolveWithDisk(allocator, "dracula.qss", dracula_qss);
        } else if (std.mem.eql(u8, name, "ayu-dark")) {
            return resolveWithDisk(allocator, "ayu-dark.qss", ayu_dark_qss);
        } else if (std.mem.eql(u8, name, "minimal")) {
            return resolveWithDisk(allocator, "minimal.qss", minimal_qss);
        } else if (std.mem.eql(u8, name, "gruvbox")) {
            return resolveWithDisk(allocator, "gruvbox.qss", gruvbox_qss);
        } else if (std.mem.eql(u8, name, "tokyonight")) {
            return resolveWithDisk(allocator, "tokyonight.qss", tokyonight_qss);
        } else if (std.mem.eql(u8, name, "catppuccin")) {
            return resolveWithDisk(allocator, "catppuccin.qss", catppuccin_qss);
        } else if (std.mem.eql(u8, name, "kanagawa")) {
            return resolveWithDisk(allocator, "kanagawa.qss", kanagawa_qss);
        } else if (std.mem.eql(u8, name, "kanagawa-lotus")) {
            return resolveWithDisk(allocator, "kanagawa-lotus.qss", kanagawa_lotus_qss);
        } else if (std.mem.eql(u8, name, "kanagawa-dragon")) {
            return resolveWithDisk(allocator, "kanagawa-dragon.qss", kanagawa_dragon_qss);
        } else if (std.mem.eql(u8, name, "everforest")) {
            return resolveWithDisk(allocator, "everforest.qss", everforest_qss);
        } else if (std.mem.eql(u8, name, "frieza")) {
            return resolveWithDisk(allocator, "frieza.qss", frieza_qss);
        } else if (std.mem.eql(u8, name, "buu")) {
            return resolveWithDisk(allocator, "buu.qss", buu_qss);
        } else if (std.mem.eql(u8, name, "nord")) {
            return resolveWithDisk(allocator, "nord.qss", nord_qss);
        } else if (std.mem.eql(u8, name, "rose-pine")) {
            return resolveWithDisk(allocator, "rose-pine.qss", rose_pine_qss);
        } else if (std.mem.eql(u8, name, "solarized-dark")) {
            return resolveWithDisk(allocator, "solarized-dark.qss", solarized_dark_qss);
        } else if (std.mem.eql(u8, name, "one-dark")) {
            return resolveWithDisk(allocator, "one-dark.qss", one_dark_qss);
        } else if (std.mem.eql(u8, name, "monokai")) {
            return resolveWithDisk(allocator, "monokai.qss", monokai_qss);
        } else if (std.mem.eql(u8, name, "palenight")) {
            return resolveWithDisk(allocator, "palenight.qss", palenight_qss);
        } else if (std.mem.eql(u8, name, "synthwave84")) {
            return resolveWithDisk(allocator, "synthwave84.qss", synthwave84_qss);
        } else if (std.mem.eql(u8, name, "ubuntu")) {
            return resolveWithDisk(allocator, "ubuntu.qss", ubuntu_qss);
        } else if (std.mem.eql(u8, name, "adwaita")) {
            return resolveWithDisk(allocator, "adwaita.qss", adwaita_qss);
        } else if (std.mem.eql(u8, name, "ubuntu-dark")) {
            return resolveWithDisk(allocator, "ubuntu-dark.qss", ubuntu_dark_qss);
        } else if (std.mem.eql(u8, name, "adwaita-dark")) {
            return resolveWithDisk(allocator, "adwaita-dark.qss", adwaita_dark_qss);
        } else if (std.mem.eql(u8, name, "cupertino")) {
            return resolveWithDisk(allocator, "cupertino.qss", cupertino_qss);
        } else if (std.mem.eql(u8, name, "cupertino-dark")) {
            return resolveWithDisk(allocator, "cupertino-dark.qss", cupertino_dark_qss);
        } else if (std.mem.eql(u8, name, "matrix")) {
            return resolveWithDisk(allocator, "matrix.qss", matrix_qss);
        } else if (std.mem.eql(u8, name, "retro")) {
            return resolveWithDisk(allocator, "retro.qss", retro_qss);
        } else if (std.mem.eql(u8, name, "win95")) {
            return resolveWithDisk(allocator, "win95.qss", win95_qss);
        } else if (std.mem.eql(u8, name, "high-contrast")) {
            return resolveWithDisk(allocator, "high-contrast.qss", high_contrast_qss);
        } else if (std.mem.eql(u8, name, "high-contrast-dark")) {
            return resolveWithDisk(allocator, "high-contrast.qss", high_contrast_qss);
        } else if (std.mem.eql(u8, name, "high-contrast-light")) {
            return resolveWithDisk(allocator, "high-contrast-light.qss", high_contrast_light_qss);
        } else if (std.mem.eql(u8, name, "github-dark")) {
            return resolveWithDisk(allocator, "github-dark.qss", github_dark_qss);
        } else if (std.mem.eql(u8, name, "github-light")) {
            return resolveWithDisk(allocator, "github-light.qss", github_light_qss);
        } else if (std.mem.eql(u8, name, "night-owl")) {
            return resolveWithDisk(allocator, "night-owl.qss", night_owl_qss);
        } else if (std.mem.eql(u8, name, "ayu-mirage")) {
            return resolveWithDisk(allocator, "ayu-mirage.qss", ayu_mirage_qss);
        } else if (std.mem.eql(u8, name, "cobalt")) {
            return resolveWithDisk(allocator, "cobalt.qss", cobalt_qss);
        } else if (std.mem.eql(u8, name, "minimal-light")) {
            return resolveWithDisk(allocator, "minimal-light.qss", minimal_light_qss);
        } else if (std.mem.eql(u8, name, "solarized-light")) {
            return resolveWithDisk(allocator, "solarized-light.qss", solarized_light_qss);
        } else if (std.mem.eql(u8, name, "one-light")) {
            return resolveWithDisk(allocator, "one-light.qss", one_light_qss);
        } else if (std.mem.eql(u8, name, "catppuccin-frappe")) {
            return resolveWithDisk(allocator, "catppuccin-frappe.qss", catppuccin_frappe_qss);
        } else if (std.mem.eql(u8, name, "catppuccin-macchiato")) {
            return resolveWithDisk(allocator, "catppuccin-macchiato.qss", catppuccin_macchiato_qss);
        } else if (std.mem.eql(u8, name, "shades-of-purple")) {
            return resolveWithDisk(allocator, "shades-of-purple.qss", shades_of_purple_qss);
        } else if (std.mem.eql(u8, name, "material")) {
            return resolveWithDisk(allocator, "material.qss", material_qss);
        } else if (std.mem.eql(u8, name, "monokai-pro")) {
            return resolveWithDisk(allocator, "monokai-pro.qss", monokai_pro_qss);
        } else if (std.mem.eql(u8, name, "breeze-dark")) {
            return resolveWithDisk(allocator, "breeze-dark.qss", breeze_dark_qss);
        } else if (std.mem.eql(u8, name, "breeze-light")) {
            return resolveWithDisk(allocator, "breeze-light.qss", breeze_light_qss);
        } else if (std.mem.eql(u8, name, "catppuccin-latte")) {
            return resolveWithDisk(allocator, "catppuccin-latte.qss", catppuccin_latte_qss);
        } else if (std.mem.eql(u8, name, "rose-pine-dawn")) {
            return resolveWithDisk(allocator, "rose-pine-dawn.qss", rose_pine_dawn_qss);
        } else if (std.mem.eql(u8, name, "tokyo-night-light")) {
            return resolveWithDisk(allocator, "tokyo-night-light.qss", tokyo_night_light_qss);
        } else if (std.mem.eql(u8, name, "tokyo-night-storm")) {
            return resolveWithDisk(allocator, "tokyo-night-storm.qss", tokyo_night_storm_qss);
        } else if (std.mem.eql(u8, name, "tokyo-night-moon")) {
            return resolveWithDisk(allocator, "tokyo-night-moon.qss", tokyo_night_moon_qss);
        } else if (std.mem.eql(u8, name, "poimandres")) {
            return resolveWithDisk(allocator, "poimandres.qss", poimandres_qss);
        } else if (std.mem.eql(u8, name, "arc-dark")) {
            return resolveWithDisk(allocator, "arc-dark.qss", arc_dark_qss);
        } else if (std.mem.eql(u8, name, "noctis")) {
            return resolveWithDisk(allocator, "noctis.qss", noctis_qss);
        } else if (std.mem.eql(u8, name, "sweet")) {
            return resolveWithDisk(allocator, "sweet.qss", sweet_qss);
        } else if (std.mem.eql(u8, name, "bulma")) {
            return resolveWithDisk(allocator, "bulma.qss", bulma_qss);
        } else if (std.mem.eql(u8, name, "gohan")) {
            return resolveWithDisk(allocator, "gohan.qss", gohan_qss);
        } else if (std.mem.eql(u8, name, "goku")) {
            return resolveWithDisk(allocator, "goku.qss", goku_qss);
        } else if (std.mem.eql(u8, name, "piccolo")) {
            return resolveWithDisk(allocator, "piccolo.qss", piccolo_qss);
        } else if (std.mem.eql(u8, name, "vegeta")) {
            return resolveWithDisk(allocator, "vegeta.qss", vegeta_qss);
        } else if (std.mem.eql(u8, name, "trunks")) {
            return resolveWithDisk(allocator, "trunks.qss", trunks_qss);
        } else if (std.mem.eql(u8, name, "tien")) {
            return resolveWithDisk(allocator, "tien.qss", tien_qss);
        } else if (std.mem.eql(u8, name, "spacegray")) {
            return resolveWithDisk(allocator, "spacegray.qss", spacegray_qss);
        } else if (std.mem.eql(u8, name, "launchpad")) {
            return resolveWithDisk(allocator, "launchpad.qss", launchpad_qss);
        } else if (std.mem.eql(u8, name, "main")) {
            return resolveWithDisk(allocator, "main.qss", main_qss);
        } else if (!std.mem.eql(u8, name, "dark")) {
            if (readThemeFile(allocator, name)) |content| {
                g_theme_qss_filename = "";
                return .{ .qss = content, .allocation = content };
            } else {
                log.info("failed to load theme: {s}, using dark", .{name});
            }
        }
    }
    return resolveWithDisk(allocator, "dark.theme.qss", dark_qss);
}

pub const ThemeEntry = struct {
    name: []const u8,
    desc: []const u8,
};

pub const theme_entries = [_]ThemeEntry{
    .{ .name = "adwaita", .desc = "Light GNOME" },
    .{ .name = "adwaita-dark", .desc = "Dark GNOME" },
    .{ .name = "arc-dark", .desc = "Classic GTK blue/gray" },
    .{ .name = "ayu-dark", .desc = "Warm dark Ayu" },
    .{ .name = "ayu-mirage", .desc = "Dusky Ayu mirage" },
    .{ .name = "breeze-dark", .desc = "KDE Plasma 6 dark" },
    .{ .name = "breeze-light", .desc = "KDE Plasma light" },
    .{ .name = "bulma", .desc = "Cyan/teal Capsule Corp genius" },
    .{ .name = "buu", .desc = "Hot pink Majin menace" },
    .{ .name = "catppuccin", .desc = "Soft pastel mocha dark" },
    .{ .name = "catppuccin-frappe", .desc = "Warm catppuccin" },
    .{ .name = "catppuccin-latte", .desc = "Light catppuccin" },
    .{ .name = "catppuccin-macchiato", .desc = "Rich catppuccin" },
    .{ .name = "cobalt", .desc = "Deep blue cobalt" },
    .{ .name = "cupertino", .desc = "Light macOS Spotlight" },
    .{ .name = "cupertino-dark", .desc = "Dark macOS Finder" },
    .{ .name = "dark", .desc = "Catppuccin Mocha dark (default)" },
    .{ .name = "dracula", .desc = "Dark purple Dracula" },
    .{ .name = "everforest", .desc = "Forest green dark" },
    .{ .name = "frieza", .desc = "Pale white/purple final form" },
    .{ .name = "github-dark", .desc = "GitHub dark" },
    .{ .name = "github-light", .desc = "GitHub light" },
    .{ .name = "gohan", .desc = "Scholarly purple DBZ" },
    .{ .name = "goku", .desc = "Dark blue + orange DBZ" },
    .{ .name = "gruvbox", .desc = "Warm earthy retro" },
    .{ .name = "high-contrast", .desc = "Bold high contrast" },
    .{ .name = "high-contrast-dark", .desc = "Bold dark high contrast" },
    .{ .name = "high-contrast-light", .desc = "Bold light high contrast" },
    .{ .name = "kanagawa", .desc = "Calm dark cyan wave" },
    .{ .name = "kanagawa-dragon", .desc = "Earthy muted kanagawa" },
    .{ .name = "kanagawa-lotus", .desc = "Warm cream kanagawa light" },
    .{ .name = "launchpad", .desc = "Dark macOS-style launcher" },
    .{ .name = "light", .desc = "Catppuccin Latte light" },
    .{ .name = "material", .desc = "Material Design teal/purple" },
    .{ .name = "matrix", .desc = "Green matrix rain" },
    .{ .name = "minimal", .desc = "Clean minimal dark" },
    .{ .name = "minimal-light", .desc = "Clean light minimal" },
    .{ .name = "monokai", .desc = "Vibrant saturated dark" },
    .{ .name = "monokai-pro", .desc = "Balanced monokai" },
    .{ .name = "night-owl", .desc = "Owl-inspired dark" },
    .{ .name = "noctis", .desc = "Deep blue-gray night" },
    .{ .name = "nord", .desc = "Frosty blue arctic" },
    .{ .name = "one-dark", .desc = "Atom's signature dark" },
    .{ .name = "one-light", .desc = "Atom light" },
    .{ .name = "palenight", .desc = "Material Palenight" },
    .{ .name = "piccolo", .desc = "Namekian guardian green" },
    .{ .name = "poimandres", .desc = "Teal/blue creative dark" },
    .{ .name = "retro", .desc = "Amber CRT phosphor" },
    .{ .name = "rose-pine", .desc = "Rosy pine forest" },
    .{ .name = "rose-pine-dawn", .desc = "Light rose pine" },
    .{ .name = "shades-of-purple", .desc = "Deep purple" },
    .{ .name = "solarized-dark", .desc = "Warm amber scientific" },
    .{ .name = "solarized-light", .desc = "Scientific light" },
    .{ .name = "spacegray", .desc = "Xcode gray dark" },
    .{ .name = "sweet", .desc = "Purple/pink candy" },
    .{ .name = "synthwave84", .desc = "Neon retro synthwave" },
    .{ .name = "tien", .desc = "Terracotta + Tri-Beam green" },
    .{ .name = "tokyonight", .desc = "Deep blue night" },
    .{ .name = "tokyo-night-light", .desc = "Light Tokyo day" },
    .{ .name = "tokyo-night-moon", .desc = "Purple Tokyo variant" },
    .{ .name = "tokyo-night-storm", .desc = "Blue Tokyo variant" },
    .{ .name = "trunks", .desc = "Lavender + Capsule Corp blue" },
    .{ .name = "ubuntu", .desc = "Warm light Ubuntu" },
    .{ .name = "ubuntu-dark", .desc = "Dark Yaru Ubuntu" },
    .{ .name = "vegeta", .desc = "Royal blue Saiyan prince" },
    .{ .name = "win95", .desc = "Classic Windows 95" },
};

pub fn listThemes(writer: anytype) !void {
    for (theme_entries) |entry| {
        try writer.print("  {s:<26} {s}\n", .{ entry.name, entry.desc });
    }
}
