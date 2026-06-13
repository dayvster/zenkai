const std = @import("std");
const lua = @import("lua_capi");

pub const Manifest = struct {
    name: []const u8,
    version: ?[]const u8,
    main: []const u8,
    description: ?[]const u8,
    author: ?[]const u8,
    disabled: ?bool,
};

pub const Hook = enum {
    on_query,
    on_open,
    on_close,
    on_startup,
    on_shutdown,
    on_keypress,
    on_idle,
    on_results,
};

pub const Plugin = struct {
    manifest: Manifest,
    dir_path: []const u8,
    state: *lua.lua_State,
    hooks: std.EnumSet(Hook),
};

pub const ResultType = enum {
    NoReturn,
    ExecCmd,
};

pub const PluginResult = struct {
    plugin_index: usize,
    id: usize,
    title: []const u8,
    subtitle: []const u8,
    icon: []const u8,
    result_type: ResultType = .ExecCmd,
};
