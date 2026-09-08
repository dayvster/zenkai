const std = @import("std");
const qt = @import("libqt6zig");
const QClipboard = qt.QClipboard;
const QMimeData = qt.QMimeData;
const QUrl = qt.QUrl;
const QImage = qt.QImage;
const clipboard = @import("history.zig");
const History = clipboard.History;
const ItemKind = clipboard.ItemKind;
const store = @import("store.zig");
const log = @import("utils").log;

var g_allocator: std.mem.Allocator = undefined;
var g_history: ?*History = null;
var g_last_text: ?[]const u8 = null;

pub fn run(allocator: std.mem.Allocator, app: anytype) !void {
    g_allocator = allocator;

    try writePidFile(allocator);

    var history = try store.load(allocator, 200);
    g_history = &history;
    defer {
        store.save(&history, allocator) catch |err| {
            log.info("failed to save clipboard history: {}", .{err});
        };
        history.deinit();
        g_history = null;
        if (g_last_text) |t| allocator.free(t);
        g_last_text = null;
        removePidFile(allocator) catch {};
    }

    const clip = app.clipboard();

    // Capture whatever is already on the clipboard so the user sees the
    // current item at the top of the history.
    captureClipboard(clip);

    clip.onDataChanged(&onClipboardChanged);

    _ = app.exec();
}

fn onClipboardChanged(clip: QClipboard) callconv(.c) void {
    captureClipboard(clip);
}

fn captureClipboard(clip: QClipboard) void {
    const allocator = g_allocator;
    const hist = g_history orelse return;

    const mime = clip.mimeData();
    defer mime.delete();

    if (mime.hasUrls()) {
        captureUrls(allocator, hist, mime);
    } else if (mime.hasImage()) {
        captureImage(allocator, hist, mime);
    } else if (mime.hasText()) {
        captureText(allocator, hist, mime);
    } else if (mime.hasHtml()) {
        captureHtml(allocator, hist, mime);
    }
}

fn captureUrls(allocator: std.mem.Allocator, hist: *History, mime: QMimeData) void {
    const urls = mime.urls(allocator);
    defer {
        for (urls) |*u| u.delete();
        allocator.free(urls);
    }
    if (urls.len == 0) return;

    const first = urls[0];
    const path = first.toLocalFile(allocator) catch return;
    defer allocator.free(path);

    const file_name = std.fs.path.basename(path);
    const display = std.fmt.allocPrint(allocator, "file: {s}", .{file_name}) catch return;
    defer allocator.free(display);

    hist.add(.file, display, path) catch |err| {
        log.info("failed to add file to clipboard history: {}", .{err});
    };
}

fn captureImage(allocator: std.mem.Allocator, hist: *History, mime: QMimeData) void {
    const image = mime.imageData();
    defer image.delete();

    // QImage has size: QSize.
    const size = image.size();
    defer size.delete();

    const display = std.fmt.allocPrint(allocator, "image: {d}x{d}", .{ size.width(), size.height() }) catch return;
    defer allocator.free(display);

    // Store a placeholder payload so we know this was an image. Restoring the
    // actual pixel data would require encoding; for now we just remember it.
    hist.add(.image, display, "") catch |err| {
        log.info("failed to add image to clipboard history: {}", .{err});
    };
}

fn captureText(allocator: std.mem.Allocator, hist: *History, mime: QMimeData) void {
    const text = mime.text(allocator) catch return;
    defer allocator.free(text);
    if (text.len == 0) return;

    // Avoid recording our own restoration of clipboard text.
    if (g_last_text) |last| {
        if (std.mem.eql(u8, last, text)) return;
    }

    hist.add(.text, text, text) catch |err| {
        log.info("failed to add text to clipboard history: {}", .{err});
    };
}

fn captureHtml(allocator: std.mem.Allocator, hist: *History, mime: QMimeData) void {
    const html = mime.html(allocator) catch return;
    defer allocator.free(html);
    if (html.len == 0) return;

    const display = std.fmt.allocPrint(allocator, "html: {d} chars", .{html.len}) catch return;
    defer allocator.free(display);

    hist.add(.html, display, html) catch |err| {
        log.info("failed to add html to clipboard history: {}", .{err});
    };
}

pub fn rememberRestoredText(allocator: std.mem.Allocator, text: []const u8) void {
    if (g_last_text) |t| allocator.free(t);
    g_last_text = allocator.dupe(u8, text) catch null;
}

fn writePidFile(allocator: std.mem.Allocator) !void {
    const path = try store.pidPath(allocator);
    defer allocator.free(path);

    const dir = std.fs.path.dirname(path) orelse return error.InvalidPath;
    try std.fs.cwd().makePath(dir);

    const pid = std.process.getPidRaw();
    const pid_str = try std.fmt.allocPrint(allocator, "{d}\n", .{pid});
    defer allocator.free(pid_str);

    try std.fs.cwd().writeFile2(.{
        .sub_path = path,
        .data = pid_str,
    });
}

fn removePidFile(allocator: std.mem.Allocator) !void {
    const path = try store.pidPath(allocator);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch {};
}

pub fn isDaemonRunning(allocator: std.mem.Allocator) bool {
    const path = store.pidPath(allocator) catch return false;
    defer allocator.free(path);

    const data = std.fs.cwd().readFileAlloc(allocator, path, 64) catch return false;
    defer allocator.free(data);

    const pid_str = std.mem.trim(u8, data, &std.ascii.whitespace);
    const pid = std.fmt.parseInt(std.posix.pid_t, pid_str, 10) catch return false;

    // signal 0 checks existence without delivering a signal.
    const rc = std.c.kill(pid, 0);
    return rc == 0;
}

pub fn ensureDaemonRunning(allocator: std.mem.Allocator) void {
    if (isDaemonRunning(allocator)) return;

    const exe = std.process.selfExePathAlloc(allocator) catch return;
    defer allocator.free(exe);

    var child = std.process.Child.init(&.{ exe, "--clipboard-daemon" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch |err| {
        log.info("failed to spawn clipboard daemon: {}", .{err});
    };
}
