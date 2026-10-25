const std = @import("std");
pub const HttpResult = struct { body: ?[]const u8 = null, status: []const u8 };

fn apiHttpGet(L: *lua.lua_State) callconv(.c) c_int {
    const raw = lua.lua_tostring(L, 1) orelse return 0;
    const get = g_active_manager.http_get orelse {
        lua.lua_pushnil(L);
        _ = lua.lua_pushstring(L, "HTTP unavailable");
        return 2;
    };
    const result = get(std.mem.span(raw));
    if (result.body) |body| {
        _ = lua.lua_pushlstring(L, body.ptr, body.len);
    } else lua.lua_pushnil(L);
    _ = lua.lua_pushlstring(L, result.status.ptr, result.status.len);
    return 2;
}
const builtin = @import("builtin");
const lua = @import("lua_capi");
const utils = @import("utils");
const config = @import("config");
const types = @import("types.zig");
const sandbox = @import("sandbox.zig");
const loader = @import("loader.zig");
const filesystem = @import("filesystem.zig");

test {
    std.testing.refAllDecls(utils.app_icons);
    std.testing.refAllDecls(filesystem);
}

pub const Manifest = types.Manifest;
pub const Hook = types.Hook;
pub const Plugin = types.Plugin;
pub const PluginResult = types.PluginResult;
pub const ResultAction = types.ResultAction;
pub const ResultType = types.ResultType;
pub const setupSandbox = sandbox.setupSandbox;
pub const callPluginMethod = sandbox.callPluginMethod;

pub fn setActiveManager(pm: *PluginManager) void {
    g_active_manager = pm;
}

var g_active_manager: *PluginManager = undefined;
var g_active_plugin_index: usize = undefined;
var g_active_results: ?*std.ArrayList(PluginResult) = null;
var g_next_result_identifier: usize = 0;
var g_pending_open_url: ?[]const u8 = null;

fn supportsCurrentPlatform(platforms: ?[][]const u8) bool {
    const supported = platforms orelse return true;
    const current_platform = @tagName(builtin.os.tag);
    for (supported) |platform| {
        if (std.ascii.eqlIgnoreCase(platform, current_platform)) return true;
    }
    return false;
}

fn apiAddResult(L: *lua.lua_State) callconv(.c) c_int {
    // Results belong to a query, never to deferred initialization/lifecycle work.
    const results = g_active_results orelse return 0;
    const title = if (lua.lua_tostring(L, 1)) |s| std.mem.sliceTo(s, 0) else "";
    const subtitle = if (lua.lua_tostring(L, 2)) |s| std.mem.sliceTo(s, 0) else "";
    const icon = if (lua.lua_tostring(L, 3)) |s| std.mem.sliceTo(s, 0) else "";
    const result_type_str = if (lua.lua_tostring(L, 4)) |s| std.mem.sliceTo(s, 0) else "";
    const exec = if (lua.lua_tostring(L, 5)) |s| std.mem.sliceTo(s, 0) else "";
    const allocator = g_active_manager.allocator;

    const result_type: types.ResultType = if (std.mem.eql(u8, result_type_str, "NoReturn"))
        .NoReturn
    else
        .ExecCmd;

    var tracked = struct {
        title: ?[]u8 = null,
        subtitle: ?[]u8 = null,
        icon: ?[]u8 = null,
        exec: ?[]u8 = null,
    }{};

    defer {
        if (tracked.title) |t| allocator.free(t);
        if (tracked.subtitle) |s| allocator.free(s);
        if (tracked.icon) |i| allocator.free(i);
        if (tracked.exec) |e| allocator.free(e);
    }

    tracked.title = allocator.dupe(u8, title) catch |err| {
        utils.log.info("plugin add_result OOM (title): {}", .{err});
        return 0;
    };
    tracked.subtitle = allocator.dupe(u8, subtitle) catch |err| {
        utils.log.info("plugin add_result OOM (subtitle): {}", .{err});
        return 0;
    };
    tracked.icon = allocator.dupe(u8, icon) catch |err| {
        utils.log.info("plugin add_result OOM (icon): {}", .{err});
        return 0;
    };
    tracked.exec = if (exec.len > 0) allocator.dupe(u8, exec) catch |err| {
        utils.log.info("plugin add_result OOM (exec): {}", .{err});
        return 0;
    } else null;

    results.append(allocator, .{
        .plugin_index = g_active_plugin_index,
        .id = g_next_result_identifier,
        .title = tracked.title.?,
        .subtitle = tracked.subtitle.?,
        .icon = tracked.icon.?,
        .exec = tracked.exec,
        .result_type = result_type,
    }) catch |err| {
        utils.log.info("plugin add_result OOM (append): {}", .{err});
        return 0;
    };

    tracked = .{};
    lua.lua_pushinteger(L, @as(i64, @intCast(g_next_result_identifier)));
    g_next_result_identifier += 1;
    return 1;
}

fn apiOpenUrl(L: *lua.lua_State) callconv(.c) c_int {
    if (g_pending_open_url) |url| {
        g_active_manager.allocator.free(url);
        g_pending_open_url = null;
    }
    if (lua.lua_tostring(L, 1)) |raw_url| {
        const url = std.mem.sliceTo(raw_url, 0);
        g_pending_open_url = g_active_manager.allocator.dupe(u8, url) catch null;
    }
    return 0;
}

fn apiLog(L: *lua.lua_State) callconv(.c) c_int {
    if (lua.lua_tostring(L, 1)) |msg| {
        utils.log.info("plugin: {s}", .{std.mem.sliceTo(msg, 0)});
    }
    return 0;
}

fn apiCopyText(L: *lua.lua_State) callconv(.c) c_int {
    const raw_text = lua.lua_tostring(L, 1) orelse return 0;
    if (g_active_manager.copy_text) |copy| {
        copy(std.mem.sliceTo(raw_text, 0));
        lua.lua_pushboolean(L, 1);
    } else {
        lua.lua_pushboolean(L, 0);
    }
    return 1;
}

fn apiOpenBrowser(L: *lua.lua_State) callconv(.c) c_int {
    const raw = lua.lua_tostring(L, 1) orelse return 0;
    const url = std.mem.sliceTo(raw, 0);
    if (!std.mem.startsWith(u8, url, "https://") and !std.mem.startsWith(u8, url, "http://")) {
        lua.lua_pushboolean(L, 0);
        return 1;
    }
    const allocator = g_active_manager.allocator;
    const opened = if (comptime builtin.os.tag == .windows)
        utils.openTarget(url, allocator)
    else
        utils.spawnTool(if (builtin.os.tag == .macos) "/usr/bin/open" else "xdg-open", &.{url}, allocator);
    opened catch |err| {
        utils.log.info("browser open failed: {}", .{err});
        lua.lua_pushboolean(L, 0);
        return 1;
    };
    lua.lua_pushboolean(L, 1);
    return 1;
}

fn apiBrowserIcon(L: *lua.lua_State) callconv(.c) c_int {
    const raw = lua.lua_tostring(L, 1) orelse return 0;
    const allocator = g_active_manager.allocator;
    const icon = utils.app_icons.browser(allocator, std.mem.sliceTo(raw, 0)) catch {
        _ = lua.lua_pushstring(L, "internet-web-browser");
        return 1;
    };
    defer allocator.free(icon);
    _ = lua.lua_pushlstring(L, icon.ptr, icon.len);
    return 1;
}

fn apiClose(_: *lua.lua_State) callconv(.c) c_int {
    g_active_manager.close_requested = true;
    return 0;
}

fn apiAddAction(L: *lua.lua_State) callconv(.c) c_int {
    const results = g_active_results orelse return 0;
    const result_id = lua.lua_tointeger(L, 1);
    const title = lua.lua_tostring(L, 2) orelse return 0;
    const action_id = lua.lua_tointeger(L, 3);
    const raw_icon = lua.lua_tostring(L, 4);
    if (result_id < 0 or action_id < 0) return 0;
    const a = g_active_manager.allocator;
    for (results.items) |*result| {
        if (result.id != result_id or result.plugin_index != g_active_plugin_index or result.actions.items.len >= 64) continue;
        const name = a.dupe(u8, std.mem.sliceTo(title, 0)) catch return 0;
        const icon = a.dupe(u8, if (raw_icon) |raw| std.mem.sliceTo(raw, 0) else "") catch {
            a.free(name);
            return 0;
        };
        result.actions.append(a, .{ .name = name, .icon = icon, .id = @intCast(action_id) }) catch {
            a.free(name);
            a.free(icon);
        };
        break;
    }
    return 0;
}

fn apiSetQuery(L: *lua.lua_State) callconv(.c) c_int {
    if (g_active_results != null) return 0;
    const raw = lua.lua_tostring(L, 1) orelse return 0;
    const pm = g_active_manager;
    const query = pm.allocator.dupe(u8, std.mem.sliceTo(raw, 0)) catch return 0;
    if (pm.pending_query) |previous| pm.allocator.free(previous);
    pm.pending_query = query;
    return 0;
}

fn pushFilesystemError(L: *lua.lua_State, err: anyerror) c_int {
    lua.lua_pushnil(L);
    const message = filesystem.errorMessage(err);
    _ = lua.lua_pushlstring(L, message.ptr, message.len);
    return 2;
}

fn pushPathInfo(L: *lua.lua_State, path: []const u8, name: []const u8, is_dir: bool, is_link: bool) void {
    lua.lua_newtable(L);
    pushLuaStrField(L, "path", path);
    pushLuaStrField(L, "name", name);
    pushLuaStrField(L, "parent", std.fs.path.dirname(path) orelse path);
    lua.lua_pushboolean(L, if (is_dir) 1 else 0);
    lua.lua_setfield(L, -2, "is_dir");
    lua.lua_pushboolean(L, if (is_link) 1 else 0);
    lua.lua_setfield(L, -2, "is_link");
    const a = g_active_manager.allocator;
    const icon = std.fmt.allocPrint(a, "native-file:{s}", .{path}) catch return;
    defer a.free(icon);
    pushLuaStrField(L, "icon", icon);
}

fn apiPathInfo(L: *lua.lua_State) callconv(.c) c_int {
    const raw = lua.lua_tostring(L, 1) orelse return 0;
    const a = g_active_manager.allocator;
    const path = filesystem.absolute(a, std.mem.sliceTo(raw, 0)) catch |err| return pushFilesystemError(L, err);
    defer a.free(path);
    const is_dir = filesystem.isDirectory(path) catch |err| return pushFilesystemError(L, err);
    pushPathInfo(L, path, std.fs.path.basename(path), is_dir, false);
    return 1;
}

fn apiReadDir(L: *lua.lua_State) callconv(.c) c_int {
    const raw = lua.lua_tostring(L, 1) orelse return 0;
    const offset = lua.lua_tointeger(L, 2);
    const filter = if (lua.lua_tostring(L, 3)) |value| std.mem.sliceTo(value, 0) else "";
    var listing = filesystem.list(g_active_manager.allocator, std.mem.sliceTo(raw, 0), @intCast(@max(offset, 0)), filter) catch |err| return pushFilesystemError(L, err);
    defer listing.deinit();
    lua.lua_newtable(L);
    pushLuaStrField(L, "path", listing.path);
    pushLuaStrField(L, "parent", std.fs.path.dirname(listing.path) orelse listing.path);
    lua.lua_pushboolean(L, if (listing.more) 1 else 0);
    lua.lua_setfield(L, -2, "more");
    lua.lua_newtable(L);
    for (listing.entries, 0..) |entry, i| {
        pushPathInfo(L, entry.path, entry.name, entry.is_dir, entry.is_link);
        lua.lua_rawseti(L, -2, @intCast(i + 1));
    }
    lua.lua_setfield(L, -2, "entries");
    return 1;
}

fn apiOpenPath(L: *lua.lua_State) callconv(.c) c_int {
    const raw = lua.lua_tostring(L, 1) orelse return 0;
    filesystem.open(g_active_manager.allocator, std.mem.sliceTo(raw, 0)) catch |err| return pushFilesystemError(L, err);
    lua.lua_pushboolean(L, 1);
    return 1;
}

fn apiExec(L: *lua.lua_State) callconv(.c) c_int {
    const allocator = g_active_manager.allocator;
    const arg_count = lua.lua_gettop(L);
    if (arg_count < 1) return 0;

    const raw_bin = lua.lua_tostring(L, 1) orelse return 0;
    const bin = std.mem.sliceTo(raw_bin, 0);
    if (bin.len == 0) return 0;

    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);

    for (1..@as(usize, @intCast(arg_count))) |i| {
        const index = @as(c_int, @intCast(i + 1));
        if (lua.lua_tostring(L, index)) |raw_arg| {
            const arg = std.mem.sliceTo(raw_arg, 0);
            args_list.append(allocator, arg) catch return 0;
        }
    }

    utils.spawnTool(bin, args_list.items, allocator) catch |err| {
        utils.log.info("plugin exec failed: {}", .{err});
    };
    return 0;
}

fn apiRun(L: *lua.lua_State) callconv(.c) c_int {
    const allocator = g_active_manager.allocator;
    const arg_count = lua.lua_gettop(L);
    if (arg_count < 1) return 0;

    const raw_bin = lua.lua_tostring(L, 1) orelse return 0;
    const bin = std.mem.sliceTo(raw_bin, 0);
    if (bin.len == 0) return 0;

    var args_list = std.ArrayList([]const u8).empty;
    defer args_list.deinit(allocator);

    for (1..@as(usize, @intCast(arg_count))) |i| {
        const index = @as(c_int, @intCast(i + 1));
        if (lua.lua_tostring(L, index)) |raw_arg| {
            const arg = std.mem.sliceTo(raw_arg, 0);
            args_list.append(allocator, arg) catch return 0;
        }
    }

    const out = allocator.alloc(u8, 64 * 1024) catch return 0;
    defer allocator.free(out);

    const result = utils.runToolTimed(bin, args_list.items, out, 2000, allocator) catch |err| {
        if (err == error.RunTimeout) {
            utils.log.info("plugin run timed out: '{s}'", .{bin});
        } else {
            utils.log.info("plugin run failed: {}", .{err});
        }
        lua.lua_pushnil(L);
        return 1;
    };

    if (result.truncated) {
        utils.log.info("plugin run output truncated for '{s}' (max {d} bytes)", .{ bin, out.len });
    }

    _ = lua.lua_pushlstring(L, out[0..result.bytes].ptr, result.bytes);
    return 1;
}

fn pushLuaStrField(L: *lua.lua_State, key: [*:0]const u8, value: []const u8) void {
    _ = lua.lua_pushlstring(L, value.ptr, value.len);
    lua.lua_setfield(L, -2, key);
}

fn tryLoadPluginConfig(self: *PluginManager, L: *lua.lua_State, path: []const u8, plugin_name: []const u8) bool {
    const config_content = loader.readFile(self.allocator, path) catch return false;
    defer self.allocator.free(config_content);

    const parsed = std.json.parseFromSlice(types.PluginConfig, self.allocator, config_content, .{ .allocate = .alloc_always }) catch |err| {
        utils.log.info("plugin '{s}': invalid config {s}: {}", .{ plugin_name, path, err });
        return false;
    };
    defer parsed.deinit();

    lua.lua_newtable(L);
    if (parsed.value.commands) |commands| {
        lua.lua_newtable(L);
        for (commands, 0..) |cmd, i| {
            lua.lua_newtable(L);
            pushLuaStrField(L, "title", cmd.title);
            if (cmd.subtitle) |subtitle| pushLuaStrField(L, "subtitle", subtitle);
            if (cmd.exec.len > 0) pushLuaStrField(L, "exec", cmd.exec);
            if (cmd.icon) |icon| pushLuaStrField(L, "icon", icon);
            if (cmd.url) |url| pushLuaStrField(L, "url", url);
            if (cmd.text) |text| pushLuaStrField(L, "text", text);
            lua.lua_rawseti(L, -2, @as(i64, @intCast(i + 1)));
        }
        lua.lua_setfield(L, -2, "commands");
    }
    if (parsed.value.replace) |replace| {
        lua.lua_pushboolean(L, if (replace) 1 else 0);
        lua.lua_setfield(L, -2, "replace");
    }
    inline for (.{ "roots", "exclude" }) |key| {
        if (@field(parsed.value, key)) |values| {
            lua.lua_newtable(L);
            for (values, 0..) |value, i| {
                _ = lua.lua_pushlstring(L, value.ptr, value.len);
                lua.lua_rawseti(L, -2, @intCast(i + 1));
            }
            lua.lua_setfield(L, -2, key);
        }
    }
    if (parsed.value.include_hidden) |hidden| {
        lua.lua_pushboolean(L, if (hidden) 1 else 0);
        lua.lua_setfield(L, -2, "include_hidden");
    }
    lua.lua_setglobal(L, "plugin_config");
    return true;
}

fn loadPluginConfig(self: *PluginManager, L: *lua.lua_State, plugins_base_dir: []const u8, dir_name: []const u8, plugin_name: []const u8) void {
    if (config.configDir(self.allocator) catch null) |cfg_dir| {
        defer self.allocator.free(cfg_dir);
        const user_file = std.fmt.allocPrint(self.allocator, "{s}.json", .{plugin_name}) catch return;
        defer self.allocator.free(user_file);
        const user_path = std.fs.path.join(self.allocator, &.{ cfg_dir, user_file }) catch return;
        defer self.allocator.free(user_path);
        if (tryLoadPluginConfig(self, L, user_path, plugin_name)) return;
    }

    const plugin_config_path = std.fs.path.join(self.allocator, &.{ plugins_base_dir, dir_name, "config.json" }) catch return;
    defer self.allocator.free(plugin_config_path);
    _ = tryLoadPluginConfig(self, L, plugin_config_path, plugin_name);
}

fn setupAPI(L: *lua.lua_State) void {
    lua.lua_newtable(L);
    lua.lua_pushcfunction(L, apiHttpGet);
    lua.lua_setfield(L, -2, "http_get");
    lua.lua_pushcfunction(L, apiAddResult);
    lua.lua_setfield(L, -2, "add_result");
    lua.lua_pushcfunction(L, apiAddAction);
    lua.lua_setfield(L, -2, "add_action");
    lua.lua_pushcfunction(L, apiSetQuery);
    lua.lua_setfield(L, -2, "set_query");
    lua.lua_pushcfunction(L, apiPathInfo);
    lua.lua_setfield(L, -2, "path_info");
    lua.lua_pushcfunction(L, apiReadDir);
    lua.lua_setfield(L, -2, "read_dir");
    lua.lua_pushcfunction(L, apiOpenPath);
    lua.lua_setfield(L, -2, "open_path");
    lua.lua_pushcfunction(L, apiLog);
    lua.lua_setfield(L, -2, "log");
    lua.lua_pushcfunction(L, apiOpenUrl);
    lua.lua_setfield(L, -2, "open_url");
    lua.lua_pushcfunction(L, apiCopyText);
    lua.lua_setfield(L, -2, "copy_text");
    lua.lua_pushcfunction(L, apiOpenBrowser);
    lua.lua_setfield(L, -2, "open_browser");
    lua.lua_pushcfunction(L, apiBrowserIcon);
    lua.lua_setfield(L, -2, "browser_icon");
    lua.lua_pushcfunction(L, apiClose);
    lua.lua_setfield(L, -2, "close");
    lua.lua_pushcfunction(L, apiExec);
    lua.lua_setfield(L, -2, "exec");
    lua.lua_pushcfunction(L, apiRun);
    lua.lua_setfield(L, -2, "run");
    lua.lua_setglobal(L, "api");
}

pub fn setup(allocator: std.mem.Allocator, plugin_filter: []const []const u8) PluginManager {
    var pm = PluginManager.init(allocator);
    pm.plugin_filter = plugin_filter;
    return pm;
}

const PendingPlugin = struct {
    manifest: std.json.Parsed(Manifest),
    base_dir: []const u8,
    dir_name: []const u8,

    fn deinit(self: PendingPlugin, allocator: std.mem.Allocator) void {
        self.manifest.deinit();
        allocator.free(self.base_dir);
        allocator.free(self.dir_name);
    }
};

pub fn matchesActivation(prefixes: []const []const u8, query: []const u8) bool {
    for (prefixes) |prefix| {
        if (prefix.len > 0 and query.len >= prefix.len and
            std.ascii.eqlIgnoreCase(query[0..prefix.len], prefix)) return true;
    }
    return false;
}

fn logPlugins(pm: *PluginManager) void {
    if (utils.log.verbose) {
        utils.log.info("loaded {d} plugin(s)", .{pm.plugins.items.len});
        for (pm.plugins.items) |plugin| {
            var hooks_buffer: [128]u8 = undefined;
            var cursor: usize = 0;
            inline for (std.meta.tags(Hook)) |hook_tag| {
                if (plugin.hooks.contains(hook_tag)) {
                    const tag_name = @tagName(hook_tag);
                    if (cursor > 0 and cursor + 2 <= hooks_buffer.len) {
                        hooks_buffer[cursor] = ',';
                        hooks_buffer[cursor + 1] = ' ';
                        cursor += 2;
                    }
                    if (cursor + tag_name.len <= hooks_buffer.len) {
                        @memcpy(hooks_buffer[cursor..][0..tag_name.len], tag_name);
                        cursor += tag_name.len;
                    }
                }
            }
            utils.log.info("  plugin '{s}' hooks: {s}", .{ plugin.manifest.name, hooks_buffer[0..cursor] });
        }
    }
}

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayList(Plugin),
    clipboard_cmd: ?[]const u8,
    url_handler: ?[]const u8,
    copy_text: ?*const fn ([]const u8) void = null,
    http_get: ?*const fn ([]const u8) HttpResult = null,

    close_requested: bool = false,
    pending_query: ?[]u8 = null,
    pending: std.ArrayList(PendingPlugin) = .empty,
    plugin_filter: []const []const u8 = &.{},
    initialized: bool = false,

    pub fn ensureInitialized(self: *PluginManager) void {
        if (self.initialized) return;
        self.initialized = true;
        setActiveManager(self);
        self.discoverAndLoad(self.plugin_filter);
        self.dispatchStartup();
        logPlugins(self);
    }

    fn activateForQuery(self: *PluginManager, query: []const u8) void {
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const pending = self.pending.items[i];
            if (!matchesActivation(pending.manifest.value.activation_prefixes.?, query)) {
                i += 1;
                continue;
            }
            // Remove before loading so a failure is not retried on every keypress.
            _ = self.pending.orderedRemove(i);
            defer pending.deinit(self.allocator);
            self.loadPlugin(pending.base_dir, pending.dir_name, false);
        }
        self.dispatchStartup();
    }

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(Plugin).empty,
            .clipboard_cmd = null,
            .url_handler = null,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        defer if (self.pending_query) |query| self.allocator.free(query);
        g_active_manager = self;
        self.dispatchClose();
        self.dispatchShutdown();
        for (self.plugins.items) |plugin| {
            lua.lua_close(plugin.state);
            self.allocator.free(plugin.manifest.name);
            self.allocator.free(plugin.manifest.main);
            self.allocator.free(plugin.dir_path);
            if (plugin.manifest.version) |v| self.allocator.free(v);
            if (plugin.manifest.description) |d| self.allocator.free(d);
            if (plugin.manifest.author) |a| self.allocator.free(a);
        }
        self.plugins.deinit(self.allocator);
        for (self.pending.items) |pending| pending.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        if (self.clipboard_cmd) |c| self.allocator.free(c);
        if (self.url_handler) |h| self.allocator.free(h);
    }

    fn scanPluginDir(self: *PluginManager, io: std.Io, dir_path: []const u8, plugin_filter: []const []const u8) void {
        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (true) {
            const entry = iter.next(io) catch break orelse break;
            if (entry.kind != .directory) continue;
            const filtered = if (plugin_filter.len > 0) blk: {
                var matched = false;
                for (plugin_filter) |name| {
                    if (std.mem.eql(u8, entry.name, name)) {
                        matched = true;
                        break;
                    }
                }
                break :blk !matched;
            } else false;
            if (filtered) continue;
            self.loadPlugin(dir_path, entry.name, true);
        }
    }

    pub fn discoverAndLoad(self: *PluginManager, plugin_filter: []const []const u8) void {
        g_active_manager = self;
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);

        if (comptime builtin.os.tag == .windows) {
            if (config.userPluginConfigDir(self.allocator) catch null) |dir_path| {
                defer self.allocator.free(dir_path);
                scanPluginDir(self, io, dir_path, plugin_filter);
            }
        } else {
            if (config.userPluginDataDir(self.allocator) catch null) |dir_path| {
                defer self.allocator.free(dir_path);
                scanPluginDir(self, io, dir_path, plugin_filter);
            }
            if (config.userPluginConfigDir(self.allocator) catch null) |dir_path| {
                defer self.allocator.free(dir_path);
                scanPluginDir(self, io, dir_path, plugin_filter);
            }
        }

        for (loader.standard_plugin_dirs) |dir_path| {
            if (std.fs.path.isAbsolute(dir_path)) {
                scanPluginDir(self, io, dir_path, plugin_filter);
                continue;
            }
            const exe_dir = std.process.executableDirPathAlloc(io, self.allocator) catch continue;
            defer self.allocator.free(exe_dir);
            const resolved = std.fs.path.join(self.allocator, &.{ exe_dir, dir_path }) catch continue;
            defer self.allocator.free(resolved);
            scanPluginDir(self, io, resolved, plugin_filter);
        }
    }

    fn loadPlugin(self: *PluginManager, plugins_base_dir: []const u8, dir_name: []const u8, allow_lazy: bool) void {
        var tracked = struct {
            name: ?[]const u8 = null,
            main: ?[]const u8 = null,
            version: ?[]const u8 = null,
            description: ?[]const u8 = null,
            author: ?[]const u8 = null,
            dir_path: ?[]const u8 = null,
            lua_state: ?*lua.lua_State = null,
        }{};

        defer {
            if (tracked.name) |v| self.allocator.free(v);
            if (tracked.main) |v| self.allocator.free(v);
            if (tracked.version) |v| self.allocator.free(v);
            if (tracked.description) |v| self.allocator.free(v);
            if (tracked.author) |v| self.allocator.free(v);
            if (tracked.dir_path) |v| self.allocator.free(v);
            if (tracked.lua_state) |s| lua.lua_close(s);
        }

        const manifest_path = std.fs.path.join(self.allocator, &.{ plugins_base_dir, dir_name, "manifest.json" }) catch return;
        defer self.allocator.free(manifest_path);

        const manifest_content = loader.readFile(self.allocator, manifest_path) catch {
            utils.log.info("plugin '{s}': manifest not readable", .{dir_name});
            return;
        };
        defer self.allocator.free(manifest_content);

        const parsed = std.json.parseFromSlice(Manifest, self.allocator, manifest_content, .{ .allocate = .alloc_always }) catch |err| {
            utils.log.info("plugin '{s}': invalid manifest: {}", .{ dir_name, err });
            return;
        };

        const parsed_manifest = parsed.value;
        if (!supportsCurrentPlatform(parsed_manifest.platforms)) {
            parsed.deinit();
            return;
        }
        if ((parsed_manifest.disabled orelse false) or parsed_manifest.name.len == 0 or parsed_manifest.main.len == 0) {
            utils.log.info("plugin '{s}': disabled or missing name/main", .{dir_name});
            parsed.deinit();
            return;
        }

        for (self.pending.items) |pending| {
            if (std.mem.eql(u8, pending.manifest.value.name, parsed_manifest.name)) {
                parsed.deinit();
                return;
            }
        }
        for (self.plugins.items) |existing| {
            if (std.mem.eql(u8, existing.manifest.name, parsed_manifest.name)) {
                parsed.deinit();
                return;
            }
        }
        if (allow_lazy) {
            if (parsed_manifest.activation_prefixes) |prefixes| {
                // Empty/invalid declarations fall back to ordinary startup.
                var valid = prefixes.len > 0;
                for (prefixes) |prefix| if (prefix.len == 0) {
                    valid = false;
                };
                if (valid) {
                    const base = self.allocator.dupe(u8, plugins_base_dir) catch {
                        parsed.deinit();
                        return;
                    };
                    const name = self.allocator.dupe(u8, dir_name) catch {
                        self.allocator.free(base);
                        parsed.deinit();
                        return;
                    };
                    self.pending.append(self.allocator, .{ .manifest = parsed, .base_dir = base, .dir_name = name }) catch {
                        self.allocator.free(base);
                        self.allocator.free(name);
                        parsed.deinit();
                    };
                    return;
                }
            }
        }

        const plugin_name = self.allocator.dupe(u8, parsed_manifest.name) catch {
            parsed.deinit();
            return;
        };
        tracked.name = plugin_name;
        const plugin_main = self.allocator.dupe(u8, parsed_manifest.main) catch {
            parsed.deinit();
            return;
        };
        tracked.main = plugin_main;
        tracked.version = if (parsed_manifest.version) |v| self.allocator.dupe(u8, v) catch null else null;
        tracked.description = if (parsed_manifest.description) |d| self.allocator.dupe(u8, d) catch null else null;
        tracked.author = if (parsed_manifest.author) |a| self.allocator.dupe(u8, a) catch null else null;
        parsed.deinit();

        for (self.plugins.items) |existing| {
            if (std.mem.eql(u8, existing.manifest.name, plugin_name)) {
                return;
            }
        }

        const main_path = std.fs.path.join(self.allocator, &.{ plugins_base_dir, dir_name, plugin_main }) catch return;
        defer self.allocator.free(main_path);

        const lua_content = loader.readFile(self.allocator, main_path) catch {
            utils.log.info("plugin '{s}': main file not readable", .{dir_name});
            return;
        };
        defer self.allocator.free(lua_content);

        const lua_state = lua.luaL_newstateOrPanic();
        tracked.lua_state = lua_state;
        lua.luaL_openlibs(lua_state);
        sandbox.setupSandbox(lua_state);
        setupAPI(lua_state);
        loadPluginConfig(self, lua_state, plugins_base_dir, dir_name, plugin_name);

        const lua_ok = lua.luaL_loadbufferx(lua_state, lua_content.ptr, lua_content.len, "plugin", null) == lua.LUA_OK and
            lua.lua_pcall(lua_state, 0, 0, 0) == lua.LUA_OK;

        if (!lua_ok) {
            utils.log.info("plugin '{s}': lua error: {s}", .{ dir_name, std.mem.sliceTo(lua.lua_tostring(lua_state, -1) orelse "unknown error", 0) });
            return;
        }

        var detected_hooks = std.EnumSet(Hook){};
        inline for (std.meta.tags(Hook)) |tag| {
            _ = lua.lua_getglobal(lua_state, @tagName(tag));
            if (lua.lua_isfunction(lua_state, -1)) {
                detected_hooks.insert(tag);
            }
            lua.lua_pop(lua_state, 1);
        }

        const dir_path = std.fs.path.join(self.allocator, &.{ plugins_base_dir, dir_name }) catch return;
        tracked.dir_path = dir_path;

        self.plugins.append(self.allocator, .{
            .manifest = .{
                .name = plugin_name,
                .version = tracked.version,
                .main = plugin_main,
                .description = tracked.description,
                .author = tracked.author,
                .disabled = false,
            },
            .dir_path = dir_path,
            .state = lua_state,
            .hooks = detected_hooks,
        }) catch return;

        tracked = .{};
        utils.log.info("loaded plugin '{s}' with {d} hook(s)", .{ plugin_name, detected_hooks.count() });
    }

    pub fn queryAll(self: *PluginManager, query: []const u8, out_results: *std.ArrayList(PluginResult)) void {
        setActiveManager(self);
        self.ensureInitialized();
        self.activateForQuery(query);
        g_active_results = out_results;
        defer g_active_results = null;
        g_next_result_identifier = 0;

        for (self.plugins.items, 0..) |*plugin, index| {
            if (!plugin.hooks.contains(.on_query)) continue;

            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_query");
            _ = lua.lua_pushlstring(plugin.state, query.ptr, query.len);
            sandbox.callPluginMethod(plugin, 1, "query error");
        }

        self.dispatchResults(out_results.items.len);
    }

    pub fn handleSelect(self: *PluginManager, result: *const PluginResult) void {
        setActiveManager(self);
        self.close_requested = false;
        switch (result.result_type) {
            .NoReturn => {},
            .ExecCmd => {
                if (result.exec) |cmd| {
                    if (cmd.len > 0) {
                        const argv = utils.tokenizeCommandLine(self.allocator, cmd) catch |err| {
                            utils.log.info("plugin exec parse failed: {}", .{err});
                            return;
                        };
                        defer {
                            for (argv) |arg| self.allocator.free(arg);
                            self.allocator.free(argv);
                        }
                        utils.executeArgv(self.allocator, argv) catch |err| {
                            utils.log.info("plugin exec failed: {}", .{err});
                        };
                    }
                }
            },
        }

        const plugin = &self.plugins.items[result.plugin_index];
        if (plugin.hooks.contains(.on_open)) {
            _ = lua.lua_getglobal(plugin.state, "on_open");
            _ = lua.lua_pushinteger(plugin.state, @as(i64, @intCast(result.id)));
            sandbox.callPluginMethod(plugin, 1, "open error");
        }

        self.flushOpenUrl();
    }

    fn flushOpenUrl(self: *PluginManager) void {
        if (g_pending_open_url) |url| {
            defer self.allocator.free(url);
            g_pending_open_url = null;

            if (url.len > 1023) return;

            if (comptime builtin.os.tag == .windows) {
                utils.openTarget(url, self.allocator) catch |err| {
                    utils.log.info("plugin URL open failed: {}", .{err});
                };
            } else {
                if (self.clipboard_cmd) |clip_cmd| {
                    if (clip_cmd.len > 0) {
                        self.writeToClipboard(clip_cmd, url);
                        return;
                    }
                }

                const handler: []const u8 = if (self.url_handler) |h|
                    h
                else if (builtin.os.tag == .macos)
                    "open"
                else
                    "xdg-open";

                utils.spawnTool(handler, &.{url}, self.allocator) catch |err| {
                    utils.log.info("url open failed: {}", .{err});
                };
            }
        }
    }

    pub fn handleAction(self: *PluginManager, result: *const PluginResult, id: usize) void {
        setActiveManager(self);
        self.close_requested = false;
        const plugin = &self.plugins.items[result.plugin_index];
        if (!plugin.hooks.contains(.on_action)) return;
        _ = lua.lua_getglobal(plugin.state, "on_action");
        _ = lua.lua_pushinteger(plugin.state, @intCast(result.id));
        _ = lua.lua_pushinteger(plugin.state, @intCast(id));
        sandbox.callPluginMethod(plugin, 2, "action error");
        self.flushOpenUrl();
    }

    fn writeToClipboard(self: *PluginManager, clip_cmd: []const u8, url: []const u8) void {
        var pipefd: [2]c_int = undefined;
        if (std.c.pipe(&pipefd) != 0) return;

        const pid = std.c.fork();
        if (pid < 0) {
            _ = std.c.close(pipefd[0]);
            _ = std.c.close(pipefd[1]);
            return;
        }

        if (pid == 0) {
            _ = std.c.close(pipefd[1]);
            _ = std.c.dup2(pipefd[0], 0);
            if (pipefd[0] != 0) _ = std.c.close(pipefd[0]);

            var buf: [1024:0]u8 = undefined;
            if (clip_cmd.len >= buf.len) std.process.exit(1);
            @memcpy(buf[0..clip_cmd.len], clip_cmd);
            buf[clip_cmd.len] = 0;
            const sh = @as([*:0]const u8, "sh");
            const c = @as([*:0]const u8, "-c");
            const argv = [_:null]?[*:0]u8{
                @constCast(sh),
                @constCast(c),
                @as([*:0]u8, @ptrCast(&buf)),
                null,
            };
            _ = std.c.execve("/bin/sh", &argv, utils.environ);
            std.c._exit(1);
        }

        _ = std.c.close(pipefd[0]);
        _ = std.c.write(pipefd[1], url.ptr, url.len);
        _ = std.c.close(pipefd[1]);

        const thread_data = self.allocator.create(ThreadData) catch return;
        thread_data.* = .{
            .pid = @as(i32, @intCast(pid)),
            .allocator = self.allocator,
        };
        const thread = std.Thread.spawn(.{}, reapChild, .{thread_data}) catch |err| {
            self.allocator.destroy(thread_data);
            var status: c_int = 0;
            _ = std.c.waitpid(@as(i32, @intCast(pid)), &status, 0);
            utils.log.info("clipboard reap thread failed: {}", .{err});
            return;
        };
        thread.detach();
    }

    pub fn dispatchStartup(self: *PluginManager) void {
        for (self.plugins.items, 0..) |*plugin, index| {
            if (plugin.startup_delivered) continue;
            plugin.startup_delivered = true;
            if (!plugin.hooks.contains(.on_startup)) continue;
            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_startup");
            sandbox.callPluginMethod(plugin, 0, "startup error");
        }
    }

    pub fn dispatchKeyPress(self: *PluginManager, key: []const u8) void {
        for (self.plugins.items, 0..) |*plugin, index| {
            if (!plugin.hooks.contains(.on_keypress)) continue;
            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_keypress");
            _ = lua.lua_pushlstring(plugin.state, key.ptr, key.len);
            sandbox.callPluginMethod(plugin, 1, "keypress error");
        }
    }

    pub fn dispatchIdle(self: *PluginManager) void {
        for (self.plugins.items, 0..) |*plugin, index| {
            if (!plugin.hooks.contains(.on_idle)) continue;
            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_idle");
            sandbox.callPluginMethod(plugin, 0, "idle error");
        }
    }

    pub fn dispatchResults(self: *PluginManager, count: usize) void {
        for (self.plugins.items, 0..) |*plugin, index| {
            if (!plugin.hooks.contains(.on_results)) continue;
            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_results");
            _ = lua.lua_pushinteger(plugin.state, @as(i64, @intCast(count)));
            sandbox.callPluginMethod(plugin, 1, "results error");
        }
    }

    pub fn dispatchClose(self: *PluginManager) void {
        for (self.plugins.items, 0..) |*plugin, index| {
            if (!plugin.hooks.contains(.on_close)) continue;
            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_close");
            sandbox.callPluginMethod(plugin, 0, "close error");
        }
    }

    pub fn dispatchShutdown(self: *PluginManager) void {
        for (self.plugins.items, 0..) |*plugin, index| {
            if (!plugin.hooks.contains(.on_shutdown)) continue;
            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_shutdown");
            sandbox.callPluginMethod(plugin, 0, "shutdown error");
        }
    }
};

const ThreadData = struct {
    pid: i32,
    allocator: std.mem.Allocator,
};

fn reapChild(data: *ThreadData) void {
    var status: c_int = 0;
    _ = std.c.waitpid(data.pid, &status, 0);
    data.allocator.destroy(data);
}

test "lazy plugin loads on first matching query and starts once" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "lazy");
    try tmp.dir.writeFile(io, .{ .sub_path = "lazy/manifest.json", .data =
        \\{"name":"lazy","main":"main.lua","version":null,"description":null,"author":null,"disabled":false,"activation_prefixes":["test:"]}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "lazy/main.lua", .data =
        \\starts = 0
        \\queries = 0
        \\function on_startup() starts = starts + 1 end
        \\function on_query(q)
        \\  queries = queries + 1
        \\  api.add_result(tostring(starts) .. ":" .. tostring(queries), "", "", "NoReturn")
        \\end
    });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    var pm = PluginManager.init(a);
    defer pm.deinit();
    pm.initialized = true; // This fixture supplies discovery, without user plugins.
    pm.loadPlugin(base, "lazy", true);
    try std.testing.expectEqual(@as(usize, 1), pm.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), pm.plugins.items.len);
    var results: std.ArrayList(PluginResult) = .empty;
    defer {
        for (results.items) |r| {
            a.free(r.title);
            a.free(r.subtitle);
            a.free(r.icon);
            if (r.exec) |exec| a.free(exec);
        }
        results.deinit(a);
    }
    pm.queryAll("browser", &results);
    try std.testing.expectEqual(@as(usize, 0), pm.plugins.items.len);
    pm.queryAll("TEST: first", &results);
    try std.testing.expectEqual(@as(usize, 1), pm.plugins.items.len);
    try std.testing.expectEqual(@as(usize, 0), pm.pending.items.len);
    try std.testing.expectEqualStrings("1:1", results.items[0].title);
    try std.testing.expectEqual(@as(usize, 0), results.items[0].plugin_index);
    pm.queryAll("test: second", &results);
    try std.testing.expectEqualStrings("1:2", results.items[1].title);
    try std.testing.expectEqual(@as(usize, 1), pm.plugins.items.len);
}

test "lazy failures are attempted once and empty prefixes preserve ordinary loading" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "broken");
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/manifest.json", .data =
        \\{"name":"broken","main":"main.lua","version":null,"description":null,"author":null,"disabled":false,"activation_prefixes":["bad:"]}
    });
    // Deliberately invalid Lua must not be read/executed during discovery.
    try tmp.dir.writeFile(io, .{ .sub_path = "broken/main.lua", .data = "this is not Lua" });
    try tmp.dir.createDirPath(io, "ordinary");
    try tmp.dir.writeFile(io, .{ .sub_path = "ordinary/manifest.json", .data =
        \\{"name":"ordinary","main":"main.lua","version":null,"description":null,"author":null,"disabled":false,"activation_prefixes":[]}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "ordinary/main.lua", .data = "function on_startup() end" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    var pm = PluginManager.init(a);
    defer pm.deinit();
    pm.initialized = true;
    pm.loadPlugin(base, "broken", true);
    pm.loadPlugin(base, "broken", true); // Duplicates must not queue twice.
    try std.testing.expectEqual(@as(usize, 1), pm.pending.items.len);
    pm.loadPlugin(base, "ordinary", true);
    try std.testing.expectEqual(@as(usize, 1), pm.plugins.items.len);
    var results: std.ArrayList(PluginResult) = .empty;
    defer results.deinit(a);
    pm.queryAll("bad: first", &results);
    try std.testing.expectEqual(@as(usize, 0), pm.pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), pm.plugins.items.len);
    pm.queryAll("bad: again", &results);
    try std.testing.expectEqual(@as(usize, 1), pm.plugins.items.len);
    try std.testing.expect(pm.plugins.items[0].startup_delivered);
}

fn runLuaTest(L: *lua.lua_State, source: [:0]const u8) !void {
    try std.testing.expectEqual(lua.LUA_OK, lua.luaL_loadstring(L, source));
    const status = lua.lua_pcall(L, 0, 0, 0);
    if (status != lua.LUA_OK) {
        if (lua.lua_tostring(L, -1)) |message| std.debug.print("{s}\n", .{message});
    }
    try std.testing.expectEqual(lua.LUA_OK, status);
}

test "bundled productivity plugins filter, encode URLs and copy exact text" {
    const a = std.testing.allocator;
    const cases = .{
        .{
            "calculator",
            \\on_query("2 + 3 * 4")
            \\assert(results[1].title == "14")
            \\on_open(1)
            \\assert(copied == "14")
            \\assert(math.abs(eval_math("sin(pi / 2)") - 1) < 1e-9)
            \\assert(eval_math("sqrt(144) + max(2, 3)") == 15)
            \\assert(eval_math("1e3 + 2.5e-1") == 1000.25)
            \\assert(eval_math("-2^2") == -4 and eval_math("2^-2") == 0.25)
            \\assert(eval_math("sqrt(-1)") == nil and eval_math("sin()") == nil)
            \\assert(eval_math("min(1,2,3)") == nil and eval_math("os.execute(1)") == nil)
            \\assert(eval_math(string.rep("(", 40) .. "1" .. string.rep(")", 40)) == nil)
            \\assert(math.abs(calculate("100 cm to m") - 1) < 1e-9)
            \\assert(math.abs(calculate("32 f to c")) < 1e-9)
            \\assert(math.abs(calculate("0 c to f") - 32) < 1e-9)
            \\assert(calculate("-274 c to k") == nil)
            \\assert(calculate("2 kg to m") == nil)
            \\assert(calculate("1 GiB to MiB") == 1024)
            \\assert(calculate("8 Mb to MB") == 1)
            \\assert(calculate("15% of 200") == 30)
            \\local requests = 0
            \\api.http_get = function(url)
            \\  requests = requests + 1
            \\  assert(url == "https://api.frankfurter.dev/v2/rates?base=USD&quotes=EUR")
            \\  return '[{"date":"2026-10-23","base":"USD","quote":"EUR","rate":0.9}]', "ok"
            \\end
            \\assert(calculate("10 USD to EUR") == 9)
            \\assert(calculate("20 USD to EUR") == 18 and requests == 1)
            \\api.http_get = function() return nil, "pending" end
            \\local value, unit, detail = calculate("10 GBP to EUR")
            \\assert(value == nil and detail == "Fetching exchange rate…")
            \\results = {}
            \\on_query("foo2bar3")
            \\assert(#results == 0)
            \\on_query("1 / 0")
            \\on_query("10 ^ 10000")
            \\assert(#results == 0)
        },
        .{
            "quicklinks",
            \\on_query("link:")
            \\assert(#results == 2 and results[1].kind == "NoReturn")
            \\results = {}
            \\on_query("LINK: a&b #c")
            \\assert(#results == 2)
            \\on_open(1)
            \\assert(opened == "https://www.google.com/search?q=a%26b%20%23c")
            \\plugin_config = {replace = true, commands = {
            \\  {title = "Docs", url = "https://example.com/docs"},
            \\  {title = "Bad", url = "javascript:alert(1)"}
            \\}}
            \\results = {}
            \\on_query("link: docs")
            \\assert(#results == 1)
            \\on_open(1)
            \\assert(opened == "https://example.com/docs")
            \\results = {}
            \\on_query("unrelated")
            \\assert(#results == 0)
        },
        .{
            "snippets",
            \\plugin_config = {commands = {{title = "Greeting", text = "hello\nworld", subtitle = "email"}}}
            \\on_query("SNIP: email")
            \\assert(#results == 1)
            \\on_open(1)
            \\assert(copied == "hello\nworld")
            \\results = {}
            \\on_query("snip: missing")
            \\on_open(1)
            \\assert(#results == 0)
        },
        .{
            "url",
            \\local accepted = {
            \\  ["www.google.com"] = "https://www.google.com",
            \\  [" example.com/path?q=a&b=2#here "] = "https://example.com/path?q=a&b=2#here",
            \\  ["HTTP://EXAMPLE.COM:8080/a"] = "http://example.com:8080/a",
            \\  ["localhost:3000/test"] = "http://localhost:3000/test",
            \\  ["https://127.0.0.1:443/"] = "https://127.0.0.1:443/",
            \\  ["xn--bcher-kva.de"] = "https://xn--bcher-kva.de"
            \\}
            \\for input, expected in pairs(accepted) do assert(normalize_url(input) == expected, input) end
            \\for _, input in ipairs({"", "hello world", "google", "foo..com", "-foo.com", "foo-.com",
            \\  "javascript:alert(1)", "file:///tmp/test", "ftp://example.com", "https://",
            \\  "https://user@example.com", "example.com:0", "example.com:65536", "999.1.2.3",
            \\  "https://example.com/a\nb", "C:\\Windows", "1 + 2", "http://example.com\\evil"}) do
            \\  assert(normalize_url(input) == nil, input)
            \\end
            \\on_query("www.google.com")
            \\assert(#results == 1)
            \\on_open(1)
            \\assert(opened_browser == "https://www.google.com" and results[1].icon == "browser-https")
            \\opened_browser = nil
            \\on_query("not a URL")
            \\on_open(1)
            \\assert(opened_browser == nil)
        },
    };
    inline for (cases) |case| {
        const manifest_source = try loader.readFile(a, "external/plugins/" ++ case[0] ++ "/manifest.json");
        defer a.free(manifest_source);
        const manifest = try std.json.parseFromSlice(Manifest, a, manifest_source, .{});
        defer manifest.deinit();
        try std.testing.expectEqualStrings(case[0], manifest.value.name);
        const L = lua.luaL_newstateOrPanic();
        defer lua.lua_close(L);
        lua.luaL_openlibs(L);
        setupSandbox(L);
        try runLuaTest(L,
            \\results = {}
            \\api = {
            \\  add_result = function(title, subtitle, icon, kind)
            \\    results[#results + 1] = {title = title, subtitle = subtitle, icon = icon, kind = kind}
            \\    return #results
            \\  end,
            \\  add_action = function() end,
            \\  copy_text = function(text) copied = text end,
            \\  open_url = function(url) opened = url end,
            \\  open_browser = function(url) opened_browser = url end,
            \\  browser_icon = function(scheme) return "browser-" .. scheme end,
            \\  log = function() end
            \\}
        );
        const source = try loader.readFile(a, "external/plugins/" ++ case[0] ++ "/main.lua");
        defer a.free(source);
        const terminated = try a.dupeSentinel(u8, source, 0);
        defer a.free(terminated);
        try runLuaTest(L, terminated);
        try runLuaTest(L, case[1]);
    }
}

test "NoReturn selection invokes its Lua hook and native clipboard callback" {
    const a = std.testing.allocator;
    var pm = PluginManager.init(a);
    defer pm.deinit();
    setActiveManager(&pm);
    const Probe = struct {
        var copied: bool = false;
        fn copy(text: []const u8) void {
            copied = std.mem.eql(u8, text, "copied from Lua");
        }
    };
    Probe.copied = false;
    pm.copy_text = Probe.copy;
    const L = lua.luaL_newstateOrPanic();
    setupAPI(L);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data =
        \\{"commands":[{"title":"Docs","url":"https://example.com"},{"title":"Text","text":"hello\nworld"}]}
    });
    const config_path = try tmp.dir.realPathFileAlloc(std.testing.io, "config.json", a);
    defer a.free(config_path);
    try std.testing.expect(tryLoadPluginConfig(&pm, L, config_path, "clipboard-test"));
    lua.luaL_openlibs(L);
    try runLuaTest(L,
        \\assert(plugin_config.commands[1].url == "https://example.com")
        \\assert(plugin_config.commands[2].text == "hello\nworld")
    );
    try runLuaTest(L, "function on_open(id) api.copy_text('copied from Lua'); api.close() end");
    try pm.plugins.append(a, .{
        .manifest = .{
            .name = try a.dupe(u8, "clipboard-test"),
            .main = try a.dupe(u8, "main.lua"),
            .version = null,
            .description = null,
            .author = null,
            .disabled = false,
        },
        .dir_path = try a.dupe(u8, "."),
        .state = L,
        .hooks = std.EnumSet(Hook).initOne(.on_open),
    });
    pm.handleSelect(&.{ .plugin_index = 0, .id = 7, .title = "", .subtitle = "", .icon = "", .result_type = .NoReturn });
    try std.testing.expect(Probe.copied);
    try std.testing.expect(pm.close_requested);
    try runLuaTest(L, "function on_open(id) end");
    pm.handleSelect(&.{ .plugin_index = 0, .id = 8, .title = "", .subtitle = "", .icon = "", .result_type = .NoReturn });
    try std.testing.expect(!pm.close_requested);
}

test "files plugin browses native paths and dispatches actions without shell parsing" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "child folder", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "a space & quote'.txt", .data = "hello" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var pm = PluginManager.init(a);
    defer pm.deinit();
    pm.initialized = true;
    setActiveManager(&pm);
    const L = lua.luaL_newstateOrPanic();
    lua.luaL_openlibs(L);
    setupSandbox(L);
    setupAPI(L);
    try pm.plugins.append(a, .{
        .manifest = .{ .name = try a.dupe(u8, "files"), .main = try a.dupe(u8, "main.lua"), .version = null, .description = null, .author = null, .disabled = false },
        .dir_path = try a.dupe(u8, "."),
        .state = L,
        .hooks = std.EnumSet(Hook).initMany(&.{ .on_query, .on_open, .on_action }),
    });
    _ = lua.lua_pushlstring(L, root.ptr, root.len);
    lua.lua_setglobal(L, "fixture_root");
    try runLuaTest(L, "plugin_config = { roots = {fixture_root} }");
    const source = try loader.readFile(a, "external/plugins/files/main.lua");
    defer a.free(source);
    const terminated = try a.dupeSentinel(u8, source, 0);
    defer a.free(terminated);
    try runLuaTest(L, terminated);
    var results: std.ArrayList(PluginResult) = .empty;
    defer {
        for (results.items) |*result| result.deinit(a);
        results.deinit(a);
    }
    pm.queryAll(root, &results);
    try std.testing.expectEqual(@as(usize, 3), results.items.len);
    try std.testing.expectEqualStrings("..", results.items[0].title);
    try std.testing.expectEqualStrings("child folder", results.items[1].title);
    try std.testing.expectEqualStrings("a space & quote'.txt", results.items[2].title);
    try std.testing.expect(std.mem.startsWith(u8, results.items[2].icon, "native-file:"));
    try std.testing.expectEqual(@as(usize, 4), results.items[2].actions.items.len);
    const Probe = struct {
        var expected: []const u8 = "";
        var copied = false;
        fn copy(value: []const u8) void {
            copied = std.mem.eql(u8, expected, value);
        }
    };
    Probe.expected = results.items[2].subtitle;
    Probe.copied = false;
    pm.copy_text = Probe.copy;
    pm.handleAction(&results.items[2], 2);
    try std.testing.expect(Probe.copied);
    try std.testing.expect(!pm.close_requested);
    pm.handleSelect(&results.items[1]);
    const next = pm.pending_query orelse return error.MissingQuery;
    pm.pending_query = null;
    defer a.free(next);
    try std.testing.expect(std.mem.indexOf(u8, next, "child folder") != null);
    for (results.items) |*result| result.deinit(a);
    results.clearRetainingCapacity();
    pm.queryAll(next, &results);
    try std.testing.expectEqualStrings("Empty folder", results.items[1].title);
    for (results.items) |*result| result.deinit(a);
    results.clearRetainingCapacity();
    pm.queryAll("file: SPACE", &results);
    try std.testing.expectEqual(@as(usize, 1), results.items.len);
    try std.testing.expectEqualStrings("a space & quote'.txt", results.items[0].title);
    for (results.items) |*result| result.deinit(a);
    results.clearRetainingCapacity();
    const partial = try std.fs.path.join(a, &.{ root, "a sp" });
    defer a.free(partial);
    pm.queryAll(partial, &results);
    try std.testing.expectEqualStrings("a space & quote'.txt", results.items[1].title);
    try runLuaTest(L, "local ok, message = api.open_path(fixture_root .. '/missing-file'); assert(ok == nil and message ~= nil)");
}
