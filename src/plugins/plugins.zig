const std = @import("std");
const lua = @import("lua_capi");
const utils = @import("utils");

pub const Manifest = struct {
    name: []const u8,
    version: ?[]const u8,
    main: []const u8,
    description: ?[]const u8,
    author: ?[]const u8,
    disabled: bool,
};

pub const Plugin = struct {
    manifest: Manifest,
    dir_path: []const u8,
    state: *lua.lua_State,
    has_on_search: bool,
    has_on_select: bool,
};

pub const PluginResult = struct {
    plugin_index: usize,
    id: usize,
    title: []const u8,
    subtitle: []const u8,
    icon: []const u8,
};

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayList(Plugin),

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        _ = allocator;
        @compileError("TODO");
    }

    pub fn deinit(self: *PluginManager) void {
        _ = self;
        @compileError("TODO");
    }

    pub fn discoverAndLoad(self: *PluginManager) !void {
        _ = self;
        @compileError("TODO");
    }

    pub fn queryAll(self: *PluginManager, query: []const u8, out_results: *std.ArrayList(PluginResult)) void {
        _ = self;
        _ = query;
        _ = out_results;
        @compileError("TODO");
    }

    pub fn handleSelect(self: *PluginManager, plugin_idx: usize, result_id: usize) void {
        _ = self;
        _ = plugin_idx;
        _ = result_id;
        @compileError("TODO");
    }
};
