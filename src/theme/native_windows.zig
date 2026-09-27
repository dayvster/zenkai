const std = @import("std");

const HKEY = ?*anyopaque;
extern "advapi32" fn RegGetValueW(
    key: HKEY,
    subkey: [*:0]const u16,
    value_name: [*:0]const u16,
    flags: u32,
    value_type: ?*u32,
    data: ?*anyopaque,
    data_size: *u32,
) callconv(.winapi) i32;
const current_user: HKEY = @ptrFromInt(@as(usize, @bitCast(@as(isize, -2147483647))));
const personalize_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
const dwm_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\DWM");
const explorer_accent_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Accent");

fn readDword(subkey: [:0]const u16, name: [:0]const u16) ?u32 {
    var value: u32 = 0;
    var size: u32 = @sizeOf(u32);
    const status = RegGetValueW(current_user, subkey, name, 0x10, null, &value, &size);
    if (status != 0 or size != @sizeOf(u32)) return null;
    return value;
}

pub const Settings = struct {
    dark: bool,
    accent: [7]u8,
};

pub fn detect() Settings {
    const light_setting = readDword(personalize_key, std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme")) orelse
        readDword(personalize_key, std.unicode.utf8ToUtf16LeStringLiteral("SystemUsesLightTheme")) orelse 1;
    // The shell's AccentColorMenu follows the accent selected in Windows
    // Settings. DWM's AccentColor can differ when Start/taskbar colorization
    // has its own saved value, so use it only as a fallback.
    const raw_accent = readDword(explorer_accent_key, std.unicode.utf8ToUtf16LeStringLiteral("AccentColorMenu")) orelse
        readDword(explorer_accent_key, std.unicode.utf8ToUtf16LeStringLiteral("StartColorMenu")) orelse
        readDword(dwm_key, std.unicode.utf8ToUtf16LeStringLiteral("AccentColor")) orelse 0xFFD77800;

    // Windows stores this color as AABBGGRR; QSS expects #RRGGBB.
    const rgb = [3]u8{
        @truncate(raw_accent),
        @truncate(raw_accent >> 8),
        @truncate(raw_accent >> 16),
    };
    const hex = "0123456789abcdef";
    var accent: [7]u8 = .{ '#', 0, 0, 0, 0, 0, 0 };
    for (rgb, 0..) |channel, i| {
        accent[1 + i * 2] = hex[channel >> 4];
        accent[2 + i * 2] = hex[channel & 0x0f];
    }
    return .{ .dark = light_setting == 0, .accent = accent };
}
