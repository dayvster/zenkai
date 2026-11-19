//! The optional background service (`zenkai --service`). zenkai starts with its window hidden
//! and stays running; `zenkai --toggle` shows the launcher and hides it again. Closing the
//! launcher (Escape, opening a result, clicking away) hides it instead of quitting, and the
//! next show starts from an empty search, like a fresh launch.
//!
//! The service keeps the app list, plugins and icons loaded between shows, and keeps the
//! clipboard history the `clip:` plugin shows. When zenkai.conf changes, it restarts itself
//! the next time it's hidden, so new settings apply.

const std = @import("std");
const qt = @import("libqt6zig");
const config = @import("config");
const lang = @import("lang");
const log = @import("utils").log;
const plugins = @import("plugins");
const service = @import("../core/service.zig");
const History = @import("../core/clipboard_history.zig").History;
const clipboard_watch = @import("clipboard_watch.zig");
const close = @import("close.zig");
const Window = @import("window.zig").Window;

const Mode = enum { launcher, window_switcher, clipboard };

var g_window: *Window = undefined;
var g_allocator: std.mem.Allocator = undefined;
var g_config_dir: ?[]const u8 = null;
var g_on_hide: ?*const fn () void = null;
var g_mode: Mode = .launcher;
var g_config_watcher: ?qt.QFileSystemWatcher = null;
var g_config_path: ?[]u8 = null;
var g_restart_pending = false;
var g_history: ?History = null;

pub const Options = struct {
    /// Where the frequency store is saved after each use, as a normal exit would.
    config_dir: ?[]const u8,
    /// Runs after every hide, for upkeep that would disturb an open launcher.
    on_hide: ?*const fn () void = null,
    /// Record copies for the `clip:` plugin. Off when that plugin is disabled.
    clipboard_history: bool = false,
};

/// Starts listening for commands, with the window hidden.
pub fn start(window: *Window, allocator: std.mem.Allocator, options: Options) service.ListenError!void {
    g_window = window;
    g_allocator = allocator;
    g_config_dir = options.config_dir;
    g_on_hide = options.on_hide;
    try service.listen(.{ .on_command = onCommand, .on_clip = onClip });
    close.hide_instead = hide;
    watchConfig();
    if (options.clipboard_history) startClipboardHistory();
    log.info("background service started; run zenkai --toggle to show the launcher", .{});
}

pub fn stop() void {
    service.stop();
    clipboard_watch.stop();
    if (g_history) |*history| history.deinit();
    g_history = null;
    close.hide_instead = null;
    if (g_config_watcher) |watcher| watcher.delete();
    g_config_watcher = null;
    if (g_config_path) |path| g_allocator.free(path);
    g_config_path = null;
}

fn onCommand(command: service.Command) void {
    switch (command) {
        .toggle_launcher => toggle(.launcher),
        .toggle_window_switcher => toggle(if (g_window.list.window_search.enabled) .window_switcher else .launcher),
        .toggle_clipboard => toggle(.clipboard),
        .quit => {
            hide();
            qt.QApplication.quit();
        },
    }
}

/// Hides the launcher when it's showing this mode, otherwise shows it in this mode, so one
/// hotkey opens and closes it and the other switches straight over.
fn toggle(mode: Mode) void {
    if (g_window.widget.isVisible() and g_mode == mode) {
        close.close();
    } else {
        show(mode);
    }
}

fn show(mode: Mode) void {
    const window = g_window;
    g_mode = mode;
    window.list.window_search.standalone = mode == .window_switcher;
    window.search_bar.setPlaceholder(switch (mode) {
        .launcher, .clipboard => lang.get().search_placeholder,
        .window_switcher => "Search windows...",
    });
    // Reset while still hidden, so a window search doesn't list zenkai itself.
    window.setQuery(if (mode == .clipboard) "clip: " else "");
    window.place();
    window.setBackdropVisible(true);
    window.show();
    window.widget.activateWindow();
    window.search_bar.focus();
}

fn hide() void {
    const window = g_window;
    if (!window.widget.isVisible()) return;
    @import("action_menu.zig").close();
    window.widget.hide();
    window.setBackdropVisible(false);
    if (window.list.plugin_manager) |manager| {
        manager.dispatchClose();
        manager.close_requested = false;
    }
    // A normal launch saves usage counts when it exits; the service saves them after each use.
    if (window.list.frequency_store) |store| {
        if (g_config_dir) |dir| store.save(dir);
    }
    if (g_restart_pending) restart();
    if (g_on_hide) |on_hide| on_hide();
}

fn startClipboardHistory() void {
    g_history = History.load(g_allocator);
    if (g_window.list.plugin_manager) |manager| {
        manager.clipboard_history = .{ .entries = clipboardEntries, .edit = editClipboard };
    }
    var path_buf: [4096:0]u8 = undefined;
    const exe = executablePath(&path_buf) orelse {
        log.info("clipboard history: can't find the zenkai binary", .{});
        return;
    };
    clipboard_watch.start(exe, onClip);
}

fn onClip(text: []const u8) void {
    const history = if (g_history) |*history| history else return;
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    history.add(text, @intCast(@divFloor(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)));
}

fn clipboardEntries() []const plugins.ClipboardEntry {
    const history = if (g_history) |*history| history else return &.{};
    return history.entries.items;
}

fn editClipboard(edit: plugins.ClipboardEdit, id: u64) bool {
    const history = if (g_history) |*history| history else return false;
    switch (edit) {
        .pin => return history.setPinned(id, true),
        .unpin => return history.setPinned(id, false),
        .delete => return history.remove(id),
        .clear => {
            history.clearUnpinned();
            return true;
        },
    }
}

/// Restarts on changes to zenkai.conf, such as saving in the settings window, so the service
/// picks up new settings without being stopped by hand.
fn watchConfig() void {
    const dir = config.configDir(g_allocator) catch return;
    defer g_allocator.free(dir);
    const path = std.fs.path.join(g_allocator, &.{ dir, "zenkai.conf" }) catch return;
    const watcher = qt.QFileSystemWatcher.new();
    _ = watcher.addPath(path);
    watcher.onFileChanged(onConfigChanged);
    g_config_watcher = watcher;
    g_config_path = path;
}

fn onConfigChanged(watcher: qt.QFileSystemWatcher, _: [*:0]const u8) callconv(.c) void {
    // Saving by writing a new file and renaming it over the old one ends the watch; watch
    // the new file instead.
    if (g_config_path) |path| _ = watcher.addPath(path);
    g_restart_pending = true;
    if (!g_window.widget.isVisible()) restart();
}

/// Runs zenkai again with the same arguments, in place, so the process ID stays the same for
/// anything supervising the service.
fn restart() void {
    log.info("zenkai.conf changed; restarting the background service", .{});
    const argv = readCmdline(g_allocator) catch |err| {
        log.info("can't restart the background service: {}", .{err});
        g_restart_pending = false;
        return;
    };
    if (g_window.list.plugin_manager) |manager| manager.dispatchShutdown();
    if (g_window.list.frequency_store) |store| {
        if (g_config_dir) |dir| store.save(dir);
    }
    // Free the socket and stop wl-paste first; the new process starts both again.
    service.stop();
    clipboard_watch.stop();
    const environ = @import("utils").environ;
    var path_buf: [4096:0]u8 = undefined;
    if (executablePath(&path_buf)) |path| _ = std.c.execve(path, argv.ptr, environ);
    // The path can be gone, say mid-upgrade; the running binary itself is always there. It
    // shows up as "exe" in process lists, so it's only the fallback.
    _ = std.c.execve("/proc/self/exe", argv.ptr, environ);
    log.info("can't restart the background service: execve failed", .{});
    std.process.exit(1);
}

/// Where this binary lives. After a package upgrade replaced it, the kernel adds
/// " (deleted)", and the path then holds the new version, which is the one to run.
fn executablePath(buf: *[4096:0]u8) ?[:0]const u8 {
    const len = std.c.readlink("/proc/self/exe", buf, buf.len);
    if (len <= 0) return null;
    const suffix = " (deleted)";
    var path = buf[0..@intCast(len)];
    if (std.mem.endsWith(u8, path, suffix)) path = path[0 .. path.len - suffix.len];
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

/// This process's arguments, from /proc/self/cmdline, as a null-terminated argv. The
/// arguments point into one buffer that lives as long as the argv; restart() never frees it,
/// since execve replaces the process.
fn readCmdline(allocator: std.mem.Allocator) ![:null]?[*:0]const u8 {
    // /proc files report a size of 0, so stream to the end instead of reading by size.
    const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);
    const file = try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, "/proc/self/cmdline", .{});
    defer std.Io.File.close(file, io);
    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.Reader.initStreaming(file, io, &buf);
    const content = try reader.interface.allocRemaining(allocator, .limited(64 * 1024));
    var args = std.ArrayList(?[*:0]const u8).empty;
    var arg_start: usize = 0;
    for (content, 0..) |byte, i| {
        if (byte != 0) continue;
        try args.append(allocator, @ptrCast(content[arg_start..i :0].ptr));
        arg_start = i + 1;
    }
    return args.toOwnedSliceSentinel(allocator, null);
}

extern fn setenv([*:0]const u8, [*:0]const u8, i32) i32;

test "the background service hides instead of quitting and shows a fresh search" {
    const a = std.testing.allocator;
    // A socket of the test's own, so a service running on this machine doesn't get in the way.
    var dir_buf: [64]u8 = undefined;
    const runtime_dir = try std.mem.printSentinel(&dir_buf, "/tmp/zenkai-test-{d}", .{std.c.getpid()}, 0);
    _ = std.c.mkdir(runtime_dir, 0o700);
    defer _ = std.c.rmdir(runtime_dir);
    _ = setenv("XDG_RUNTIME_DIR", runtime_dir, 1);

    var argc: i32 = 1;
    var arg = "zenkai".*;
    var argv = [_][:0]u8{&arg};
    const app = qt.QApplication.new(std.heap.page_allocator, &argc, &argv);
    defer app.delete();
    var window: Window = undefined;
    window.init(a, &.{}, .{ .no_animations = true }, true, true, app);
    defer window.deinit();

    try start(&window, a, .{ .config_dir = null });
    defer stop();
    try std.testing.expectError(error.AlreadyRunning, service.listen(.{ .on_command = onCommand, .on_clip = onClip }));

    try std.testing.expect(service.send(.toggle_launcher));
    for (0..20) |_| qt.QApplication.processEvents();
    try std.testing.expect(window.widget.isVisible());

    window.search_bar.setText("leftover");
    @import("animation.zig").animateFadeOutAndClose();
    try std.testing.expect(!window.widget.isVisible());

    try std.testing.expect(service.send(.toggle_window_switcher));
    for (0..20) |_| qt.QApplication.processEvents();
    try std.testing.expect(window.widget.isVisible());
    try std.testing.expect(window.list.window_search.standalone);
    const text = window.search_bar.widget.text(a);
    defer a.free(text);
    try std.testing.expectEqualStrings("", text);
}

test "the restart reads this process's arguments" {
    // The arguments point into the file's contents, so both go at once.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const argv = try readCmdline(arena.allocator());
    try std.testing.expect(argv.len >= 1 and argv[0] != null);
}
