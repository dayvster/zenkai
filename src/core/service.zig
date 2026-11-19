//! The socket between the optional background service (`zenkai --service`) and the commands
//! that drive it (`zenkai --toggle`, `zenkai --quit-service`).
//!
//! The service listens with a QLocalServer, which on Unix is a plain Unix domain socket. The
//! commands connect with raw sockets before Qt starts, so toggling the launcher costs a
//! connect and a write instead of a Qt startup. Each connection carries one command line.

const std = @import("std");
const builtin = @import("builtin");
const qt = @import("libqt6zig");
const log = @import("utils").log;

/// Linux only for now. macOS and Windows need their own work for showing a hidden window
/// and focusing it, so the flags say so there instead of half working.
pub const supported = builtin.os.tag == .linux;

pub const Command = enum {
    toggle_launcher,
    toggle_window_switcher,
    quit,

    const all = [_]Command{ .toggle_launcher, .toggle_window_switcher, .quit };

    fn line(self: Command) []const u8 {
        return switch (self) {
            .toggle_launcher => "toggle launcher\n",
            .toggle_window_switcher => "toggle window-switcher\n",
            .quit => "quit\n",
        };
    }

    fn parse(text: []const u8) ?Command {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        for (all) |command| {
            if (std.mem.eql(u8, trimmed, std.mem.trimEnd(u8, command.line(), "\n"))) return command;
        }
        return null;
    }
};

const max_path = @typeInfo(@FieldType(std.c.sockaddr.un, "path")).array.len;

/// `$XDG_RUNTIME_DIR/zenkai.sock`, which only this user can reach, or a per-user name in
/// /tmp when there's no runtime directory.
fn socketPath(buf: *[max_path]u8) ?[:0]const u8 {
    const path = if (std.c.getenv("XDG_RUNTIME_DIR")) |dir|
        std.mem.printSentinel(buf, "{s}/zenkai.sock", .{std.mem.span(dir)}, 0)
    else
        std.mem.printSentinel(buf, "/tmp/zenkai-{d}.sock", .{std.c.getuid()}, 0);
    return path catch null;
}

/// Sends a command to the running service. False when no service is listening.
pub fn send(command: Command) bool {
    if (comptime !supported) return false;
    var path_buf: [max_path]u8 = undefined;
    const path = socketPath(&path_buf) orelse return false;

    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);

    var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) return false;

    const line = command.line();
    return std.c.write(fd, line.ptr, line.len) == @as(isize, @intCast(line.len));
}

var g_server: ?qt.QLocalServer = null;
var g_on_command: *const fn (Command) void = undefined;

pub const ListenError = error{ AlreadyRunning, SocketPath, ListenFailed };

/// Starts listening for commands. Fails with AlreadyRunning when another service answers on
/// the socket; a socket file left behind by a service that crashed is replaced.
pub fn listen(on_command: *const fn (Command) void) ListenError!void {
    var path_buf: [max_path]u8 = undefined;
    const path = socketPath(&path_buf) orelse return error.SocketPath;
    if (connectable(path)) return error.AlreadyRunning;
    _ = qt.QLocalServer.removeServer(path);

    const server = qt.QLocalServer.new();
    server.setSocketOptions(qt.qlocalserver_enums.SocketOption.UserAccessOption);
    if (!server.listen(path)) {
        const message = server.errorString(std.heap.c_allocator);
        defer std.heap.c_allocator.free(message);
        log.info("background service: can't listen on {s}: {s}", .{ path, message });
        server.delete();
        return error.ListenFailed;
    }
    g_on_command = on_command;
    server.onNewConnection(onNewConnection);
    g_server = server;
}

/// Stops listening and removes the socket file, so commands fall back to starting zenkai.
pub fn stop() void {
    const server = g_server orelse return;
    server.close();
    server.delete();
    g_server = null;
}

fn connectable(path: [:0]const u8) bool {
    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM | std.c.SOCK.CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var addr: std.c.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(addr.path[0..path.len], path);
    return std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) == 0;
}

fn onNewConnection(server: qt.QLocalServer) callconv(.c) void {
    while (server.hasPendingConnections()) {
        const socket = server.nextPendingConnection();
        defer socket.deleteLater();
        // The command is one short line, written right after connecting.
        if (!socket.waitForReadyRead(200)) continue;
        const data = socket.readAll(std.heap.c_allocator);
        defer std.heap.c_allocator.free(data);
        if (Command.parse(data)) |command| {
            g_on_command(command);
        } else {
            log.info("background service: unknown command '{s}'", .{std.mem.trim(u8, data, " \t\r\n")});
        }
    }
}

test "commands survive the trip through their wire format" {
    for (Command.all) |command| {
        try std.testing.expectEqual(command, Command.parse(command.line()).?);
    }
    try std.testing.expectEqual(null, Command.parse("toggle"));
    try std.testing.expectEqual(null, Command.parse(""));
}

test "socket path prefers the runtime directory" {
    var buf: [max_path]u8 = undefined;
    const path = socketPath(&buf) orelse return error.NoPath;
    if (std.c.getenv("XDG_RUNTIME_DIR")) |dir| {
        try std.testing.expect(std.mem.startsWith(u8, path, std.mem.span(dir)));
    }
    try std.testing.expect(std.mem.endsWith(u8, path, ".sock"));
}
