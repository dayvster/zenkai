const std = @import("std");
const lua = @import("lua_capi");
const utils = @import("utils");
const types = @import("types.zig");
const sandbox = @import("sandbox.zig");
const loader = @import("loader.zig");

pub const Manifest = types.Manifest;
pub const Hook = types.Hook;
pub const Plugin = types.Plugin;
pub const PluginResult = types.PluginResult;
pub const setupSandbox = sandbox.setupSandbox;
pub const callPluginMethod = sandbox.callPluginMethod;

var g_active_manager: *PluginManager = undefined;
var g_active_plugin_index: usize = undefined;
var g_active_results: *std.ArrayList(PluginResult) = undefined;
var g_next_result_identifier: usize = 0;
var g_pending_open_url: ?[]const u8 = null;

extern "c" var environ: [*:null]?[*:0]u8;

fn apiAddResult(L: *lua.lua_State) callconv(.c) c_int {
    const title = if (lua.lua_tostring(L, 1)) |s| std.mem.sliceTo(s, 0) else "";
    const subtitle = if (lua.lua_tostring(L, 2)) |s| std.mem.sliceTo(s, 0) else "";
    const icon = if (lua.lua_tostring(L, 3)) |s| std.mem.sliceTo(s, 0) else "";
    const allocator = g_active_manager.allocator;

    var tracked = struct {
        title: ?[]u8 = null,
        subtitle: ?[]u8 = null,
        icon: ?[]u8 = null,
    }{};

    defer {
        if (tracked.title) |t| allocator.free(t);
        if (tracked.subtitle) |s| allocator.free(s);
        if (tracked.icon) |i| allocator.free(i);
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

    g_active_results.append(allocator, .{
        .plugin_index = g_active_plugin_index,
        .id = g_next_result_identifier,
        .title = tracked.title.?,
        .subtitle = tracked.subtitle.?,
        .icon = tracked.icon.?,
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

fn setupAPI(L: *lua.lua_State) void {
    lua.lua_newtable(L);
    lua.lua_pushcfunction(L, apiAddResult);
    lua.lua_setfield(L, -2, "add_result");
    lua.lua_pushcfunction(L, apiLog);
    lua.lua_setfield(L, -2, "log");
    lua.lua_pushcfunction(L, apiOpenUrl);
    lua.lua_setfield(L, -2, "open_url");
    lua.lua_setglobal(L, "api");
}

pub fn setup(allocator: std.mem.Allocator) PluginManager {
    var pm = PluginManager.init(allocator);
    pm.discoverAndLoad();
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
    return pm;
}

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.ArrayList(Plugin),

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(Plugin).empty,
        };
    }

    pub fn deinit(self: *PluginManager) void {
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
    }

    fn scanPluginDir(self: *PluginManager, io: std.Io, dir_path: []const u8) void {
        var dir = std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true }) catch return;
        defer dir.close(io);

        var iter = dir.iterate();
        while (true) {
            const entry = iter.next(io) catch break orelse break;
            if (entry.kind != .directory) continue;
            self.loadPlugin(dir_path, entry.name);
        }
    }

    pub fn discoverAndLoad(self: *PluginManager) void {
        g_active_manager = self;
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);

        if (std.c.getenv("HOME")) |home| {
            const home_slice = std.mem.sliceTo(home, 0);
            if (std.fs.path.join(self.allocator, &.{ home_slice, ".local", "share", "zenkai", "plugins" })) |dir_path| {
                defer self.allocator.free(dir_path);
                scanPluginDir(self, io, dir_path);
            } else |_| {}
            if (std.fs.path.join(self.allocator, &.{ home_slice, ".config", "zenkai", "plugins" })) |dir_path| {
                defer self.allocator.free(dir_path);
                scanPluginDir(self, io, dir_path);
            } else |_| {}
        }

        for (loader.standard_plugin_dirs) |dir_path| {
            scanPluginDir(self, io, dir_path);
        }
    }

    fn loadPlugin(self: *PluginManager, plugins_base_dir: []const u8, dir_name: []const u8) void {
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
        if ((parsed_manifest.disabled orelse false) or parsed_manifest.name.len == 0 or parsed_manifest.main.len == 0) {
            utils.log.info("plugin '{s}': disabled or missing name/main", .{dir_name});
            parsed.deinit();
            return;
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
        g_active_results = out_results;
        g_next_result_identifier = 0;

        for (self.plugins.items, 0..) |*plugin, index| {
            if (!plugin.hooks.contains(.on_query)) continue;

            g_active_plugin_index = index;
            _ = lua.lua_getglobal(plugin.state, "on_query");
            _ = lua.lua_pushlstring(plugin.state, query.ptr, query.len);
            sandbox.callPluginMethod(plugin, 1, "query error");
        }
    }

    pub fn handleSelect(self: *PluginManager, plugin_index: usize, result_identifier: usize) void {
        const plugin = &self.plugins.items[plugin_index];
        if (!plugin.hooks.contains(.on_open)) return;

        _ = lua.lua_getglobal(plugin.state, "on_open");
        lua.lua_pushinteger(plugin.state, @as(i64, @intCast(result_identifier)));
        sandbox.callPluginMethod(plugin, 1, "open error");

        if (g_pending_open_url) |url| {
            const url_z = self.allocator.dupeZ(u8, url) catch {
                self.allocator.free(url);
                g_pending_open_url = null;
                return;
            };
            defer self.allocator.free(url_z);
            self.allocator.free(url);
            g_pending_open_url = null;

            const xdg_open = @as([*:0]const u8, "xdg-open");
            const argv = [_:null]?[*:0]u8{
                @constCast(xdg_open),
                url_z,
                null,
            };
            const pid = std.os.linux.fork();
            if (std.os.linux.errno(pid) == .SUCCESS and pid == 0) {
                _ = std.os.linux.execve("/usr/bin/xdg-open", &argv, environ);
                _ = std.os.linux.execve("/bin/xdg-open", &argv, environ);
                std.os.linux.exit(1);
            }
        }
    }
};
