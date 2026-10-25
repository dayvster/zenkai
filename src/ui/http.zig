const std = @import("std");
const qt = @import("libqt6zig");
const plugins = @import("plugins");
const a = std.heap.page_allocator;
const Entry = struct { url: []u8, reply: ?qt.QNetworkReply, body: std.ArrayList(u8) = .empty, failed: bool = false };
var manager: ?qt.QNetworkAccessManager = null;
var entries: std.ArrayList(Entry) = .empty;
pub var on_complete: ?*const fn () void = null;

pub fn get(url: []const u8) plugins.HttpResult {
    if (!std.mem.startsWith(u8, url, "https://") or url.len > 2048 or std.mem.indexOfAny(u8, url, "\r\n\x00") != null) return .{ .status = "invalid HTTPS URL" };
    for (entries.items) |entry| {
        if (std.mem.eql(u8, entry.url, url)) return if (entry.reply != null) .{ .status = "pending" } else if (entry.failed) .{ .status = "request failed" } else .{ .body = entry.body.items, .status = "ok" };
    }
    if (entries.items.len >= 32) return .{ .status = "request limit reached" };
    const owned = a.dupe(u8, url) catch return .{ .status = "out of memory" };
    const parsed = qt.QUrl.new3(url);
    defer parsed.delete();
    const request = qt.QNetworkRequest.new2(parsed);
    defer request.delete();
    request.setTransferTimeout(5000);
    if (manager == null) manager = qt.QNetworkAccessManager.new();
    const reply = manager.?.get(request);
    reply.setReadBufferSize(65536);
    entries.append(a, .{ .url = owned, .reply = reply }) catch {
        a.free(owned);
        reply.abort();
        reply.deleteLater();
        return .{ .status = "out of memory" };
    };
    reply.onReadyRead(read);
    reply.onFinished(finished);
    return .{ .status = "pending" };
}
fn find(reply: qt.QNetworkReply) ?*Entry {
    for (entries.items) |*entry| if (entry.reply) |pending| {
        if (pending.ptr == reply.ptr) return entry;
    };
    return null;
}
fn read(reply: qt.QNetworkReply) callconv(.c) void {
    const entry = find(reply) orelse return;
    if (entry.failed) return;
    if (reply.bytesAvailable() > 65536 - entry.body.items.len) {
        entry.failed = true;
        reply.abort();
        return;
    }
    const bytes = reply.readAll(a);
    defer a.free(bytes);
    entry.body.appendSlice(a, bytes) catch {
        entry.failed = true;
        reply.abort();
    };
}
fn finished(reply: qt.QNetworkReply) callconv(.c) void {
    read(reply);
    const entry = find(reply) orelse return;
    entry.failed = entry.failed or reply.error0() != 0;
    entry.reply = null;
    reply.deleteLater();
    if (on_complete) |callback| callback();
}
pub fn deinit() void {
    on_complete = null;
    // Disconnect callbacks by deleting the manager/replies before releasing state.
    if (manager) |network| network.delete();
    manager = null;
    for (entries.items) |*entry| {
        a.free(entry.url);
        entry.body.deinit(a);
    }
    entries.deinit(a);
    entries = .empty;
}

test "HTTP bridge rejects non-HTTPS without a network request" {
    try std.testing.expectEqualStrings("invalid HTTPS URL", get("file:///etc/passwd").status);
    try std.testing.expectEqualStrings("invalid HTTPS URL", get("https://example.com\r\nX-Test: injected").status);
}

test "live HTTPS fetch completes asynchronously when explicitly enabled" {
    if (std.c.getenv("ZENKAI_HTTP_SMOKE") == null) return error.SkipZigTest;
    var argc: i32 = 1;
    var arg = [_:0]u8{ 'z', 'e', 'n', 'k', 'a', 'i' };
    var argv = [_][:0]u8{arg[0.. :0]};
    const app = qt.QApplication.new(a, &argc, &argv);
    defer app.delete();
    defer deinit();
    const Probe = struct {
        fn complete() void {
            qt.QApplication.quit();
        }
        fn timeout(_: qt.QTimer) callconv(.c) void {
            qt.QApplication.quit();
        }
    };
    on_complete = Probe.complete;
    const url = "https://api.frankfurter.dev/v2/rates?base=USD&quotes=EUR";
    try std.testing.expectEqualStrings("pending", get(url).status);
    const timer = qt.QTimer.new();
    defer timer.delete();
    timer.setSingleShot(true);
    timer.onTimeout(Probe.timeout);
    timer.start(10000);
    _ = qt.QApplication.exec();
    const result = get(url);
    try std.testing.expectEqualStrings("ok", result.status);
    const body = result.body orelse return error.NoResponse;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array and parsed.value.array.items.len == 1);
}
