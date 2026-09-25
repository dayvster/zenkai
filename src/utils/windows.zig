const std = @import("std");

extern "shell32" fn ShellExecuteW(
    hwnd: ?*anyopaque,
    operation: [*:0]const u16,
    file: [*:0]const u16,
    parameters: ?[*:0]const u16,
    directory: ?[*:0]const u16,
    show_cmd: i32,
) callconv(.winapi) isize;

fn toWideZ(allocator: std.mem.Allocator, value: []const u8) ![:0]u16 {
    const wide = try std.unicode.utf8ToUtf16LeAlloc(allocator, value);
    defer allocator.free(wide);
    return try allocator.dupeZ(u16, wide);
}

/// Open a file, URL, executable, or Windows shortcut through its registered handler.
pub fn open(allocator: std.mem.Allocator, target: []const u8) !void {
    const operation = try toWideZ(allocator, "open");
    defer allocator.free(operation);
    const file = try toWideZ(allocator, target);
    defer allocator.free(file);
    const result = ShellExecuteW(null, operation, file, null, null, 1);
    if (result <= 32) return error.ShellExecuteFailed;
}

pub fn openCommandLine(allocator: std.mem.Allocator, command_line: []const u8) !void {
    const line = std.mem.trim(u8, command_line, " \t\r\n");
    if (line.len == 0) return error.EmptyCommand;

    var executable: []const u8 = undefined;
    var parameters: []const u8 = "";
    if (line[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, line, 1, '"') orelse return error.UnclosedCommandQuote;
        executable = line[1..close];
        parameters = std.mem.trimStart(u8, line[close + 1 ..], " \t");
    } else if (std.mem.indexOfAny(u8, line, " \t")) |space| {
        executable = line[0..space];
        parameters = std.mem.trimStart(u8, line[space..], " \t");
    } else {
        executable = line;
    }
    return openCommand(allocator, executable, parameters);
}

pub fn openCommand(allocator: std.mem.Allocator, executable: []const u8, parameters: []const u8) !void {
    const operation = try toWideZ(allocator, "open");
    defer allocator.free(operation);
    const file = try toWideZ(allocator, executable);
    defer allocator.free(file);
    const wide_parameters = try toWideZ(allocator, parameters);
    defer allocator.free(wide_parameters);
    const result = ShellExecuteW(null, operation, file, wide_parameters, null, 1);
    if (result <= 32) return error.ShellExecuteFailed;
}

pub fn openArgv(allocator: std.mem.Allocator, executable: []const u8, args: []const []const u8) !void {
    var parameters_list: std.ArrayList(u8) = .empty;
    defer parameters_list.deinit(allocator);
    for (args, 0..) |arg, index| {
        if (index > 0) try parameters_list.append(allocator, ' ');
        try appendQuotedArgument(&parameters_list, allocator, arg);
    }
    const parameters = try parameters_list.toOwnedSlice(allocator);
    defer allocator.free(parameters);
    return openCommand(allocator, executable, parameters);
}

fn appendQuotedArgument(out: *std.ArrayList(u8), allocator: std.mem.Allocator, arg: []const u8) !void {
    try out.append(allocator, '"');
    var backslashes: usize = 0;
    for (arg) |char| {
        if (char == '\\') {
            backslashes += 1;
            continue;
        }

        const slash_count = if (char == '"') backslashes * 2 + 1 else backslashes;
        for (0..slash_count) |_| try out.append(allocator, '\\');
        try out.append(allocator, char);
        backslashes = 0;
    }
    for (0..backslashes * 2) |_| try out.append(allocator, '\\');
    try out.append(allocator, '"');
}
