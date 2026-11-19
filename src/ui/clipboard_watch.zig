//! Feeds the background service's clipboard history.
//!
//! On Wayland an app can't see the clipboard while it isn't focused, so `wl-paste --watch`
//! (from wl-clipboard) runs `zenkai --clipboard-store` for every copy, which hands the text
//! to the service over its socket. That needs a compositor with the data-control protocol:
//! Hyprland, Sway and KDE Plasma have it, GNOME doesn't. On X11, Qt reports clipboard
//! changes itself.
//!
//! Copies that password managers mark as secret are left out on both.

const std = @import("std");
const qt = @import("libqt6zig");
const utils = @import("utils");
const log = utils.log;

var g_on_copy: *const fn ([]const u8) void = undefined;
var g_wl_paste: ?std.c.pid_t = null;
var g_check_timer: ?qt.QTimer = null;

/// Starts watching. `exe` is this binary, which wl-paste runs for each copy.
pub fn start(exe: [:0]const u8, on_copy: *const fn ([]const u8) void) void {
    g_on_copy = on_copy;
    const platform = qt.QApplication.platformName(std.heap.c_allocator);
    defer std.heap.c_allocator.free(platform);
    if (std.mem.eql(u8, platform, "wayland")) {
        startWlPaste(exe);
    } else if (std.mem.eql(u8, platform, "xcb")) {
        qt.QApplication.clipboard().onDataChanged(onX11Changed);
    } else {
        log.info("clipboard history isn't available on the {s} platform", .{platform});
    }
}

/// Stops wl-paste, which would otherwise keep running after a restart and store every copy
/// twice.
pub fn stop() void {
    if (g_check_timer) |timer| timer.delete();
    g_check_timer = null;
    const pid = g_wl_paste orelse return;
    _ = std.c.kill(pid, std.c.SIG.TERM);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    g_wl_paste = null;
}

fn startWlPaste(exe: [:0]const u8) void {
    const allocator = std.heap.c_allocator;
    const wl_paste = utils.toolPath(allocator, "wl-paste") orelse {
        log.info("clipboard history needs wl-paste on Wayland; install wl-clipboard", .{});
        return;
    };
    defer allocator.free(wl_paste);
    const path = allocator.dupeSentinel(u8, wl_paste, 0) catch return;
    defer allocator.free(path);
    // Asking for UTF-8 plain text by name keeps wl-paste from picking a type like browsers'
    // UTF-16 text/x-moz-url when both are offered.
    const argv = [_:null]?[*:0]const u8{ path, "--type", "text/plain;charset=utf-8", "--watch", exe, "--clipboard-store" };

    const pid = std.c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        // Ends wl-paste with the service, even when the service crashes.
        _ = std.c.prctl(@backingInt(std.os.linux.PR.SET_PDEATHSIG), @as(c_ulong, @backingInt(std.c.SIG.TERM)));
        _ = std.c.execve(path, &argv, utils.environ);
        std.c._exit(127);
    }
    g_wl_paste = pid;

    // wl-paste exits straight away when the compositor can't share the clipboard; say why
    // instead of silently recording nothing.
    const timer = qt.QTimer.new();
    timer.setSingleShot(true);
    timer.onTimeout(onCheckWlPaste);
    timer.start(2000);
    g_check_timer = timer;
}

fn onCheckWlPaste(_: qt.QTimer) callconv(.c) void {
    const pid = g_wl_paste orelse return;
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, std.c.W.NOHANG) != pid) return;
    g_wl_paste = null;
    log.info("clipboard history: wl-paste stopped; this compositor may not support the data-control protocol", .{});
}

fn onX11Changed(clipboard: qt.QClipboard) callconv(.c) void {
    const allocator = std.heap.c_allocator;
    const mime = clipboard.mimeData();
    if (mime.hasFormat(password_hint)) {
        const hint = mime.data(allocator, password_hint);
        defer allocator.free(hint);
        if (std.mem.eql(u8, hint, "secret")) return;
    }
    const text = clipboard.text(allocator);
    defer allocator.free(text);
    g_on_copy(text);
}

/// Set by KeePassXC, KDE Wallet and others on passwords they copy.
const password_hint = "x-kde-passwordManagerHint";

/// Whether wl-paste's CLIPBOARD_STATE says there's text worth keeping: "data", or unset with
/// older wl-clipboard. "sensitive" marks passwords; "nil" and "clear" an empty clipboard.
pub fn shouldStore(clipboard_state: ?[]const u8) bool {
    const state = clipboard_state orelse return true;
    return std.mem.eql(u8, state, "data");
}

test "only plain clipboard data is stored" {
    try std.testing.expect(shouldStore(null));
    try std.testing.expect(shouldStore("data"));
    try std.testing.expect(!shouldStore("sensitive"));
    try std.testing.expect(!shouldStore("nil"));
    try std.testing.expect(!shouldStore("clear"));
}
