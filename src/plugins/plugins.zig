const std = @import("std");
const lua = @import("lua_capi");
const utils = @import("utils");
const config = @import("config");
const types = @import("types.zig");
const sandbox = @import("sandbox.zig");
const loader = @import("loader.zig");

pub const Manifest = types.Manifest;
pub const Hook = types.Hook;
pub const Plugin = types.Plugin;
pub const PluginResult = types.PluginResult;
pub const ResultType = types.ResultType;
pub const setupSandbox = sandbox.setupSandbox;
pub const callPluginMethod = sandbox.callPluginMethod;

pub fn setActiveManager(pm: *PluginManager) void {
    g_active_manager = pm;
}

var g_active_manager: *PluginManager = undefined;
var g_active_plugin_index: usize = undefined;
var g_active_results: *std.ArrayList(PluginResult) = undefined;
var g_next_result_identifier: usize = 0;
var g_pending_open_url: ?[]const u8 = null;

fn apiAddResult(L: *lua.lua_State) callconv(.c) c_int {
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

    g_active_results.append(allocator, .{
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

    const written = utils.runTool(bin, args_list.items, out, allocator) catch |err| {
        utils.log.info("plugin run failed: {}", .{err});
        lua.lua_pushnil(L);
        return 1;
    };

    lua.lua_pushlstring(L, out[0..written].ptr, written);
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
            lua.lua_rawseti(L, -2, @as(i64, @intCast(i + 1)));
        }
        lua.lua_setfield(L, -2, "commands");
    }
    if (parsed.value.replace) |replace| {
        lua.lua_pushboolean(L, if (replace) 1 else 0);
        lua.lua_setfield(L, -2, "replace");
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
    lua.lua_pushcfunction(L, apiAddResult);
    lua.lua_setfield(L, -2, "add_result");
    lua.lua_pushcfunction(L, apiLog);
    lua.lua_setfield(L, -2, "log");
    lua.lua_pushcfunction(L, apiOpenUrl);
    lua.lua_setfield(L, -2, "open_url");
    lua.lua_pushcfunction(L, apiExec);
    lua.lua_setfield(L, -2, "exec");
    lua.lua_pushcfunction(L, apiRun);
    lua.lua_setfield(L, -2, "run");
    lua.lua_setglobal(L, "api");
}

pub fn setup(allocator: std.mem.Allocator, plugin_filter: []const []const u8) PluginManager {
    var pm = PluginManager.init(allocator);
    pm.discoverAndLoad(plugin_filter);
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
    clipboard_cmd: ?[]const u8,
    url_handler: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return .{
            .allocator = allocator,
            .plugins = std.ArrayList(Plugin).empty,
            .clipboard_cmd = null,
            .url_handler = null,
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
            self.loadPlugin(dir_path, entry.name);
        }
    }

    pub fn discoverAndLoad(self: *PluginManager, plugin_filter: []const []const u8) void {
        g_active_manager = self;
        const io = std.Io.Threaded.io(std.Io.Threaded.global_single_threaded);

        if (std.c.getenv("HOME")) |home| {
            const home_slice = std.mem.sliceTo(home, 0);
            if (std.fs.path.join(self.allocator, &.{ home_slice, ".local", "share", "zenkai", "plugins" })) |dir_path| {
                defer self.allocator.free(dir_path);
                scanPluginDir(self, io, dir_path, plugin_filter);
            } else |_| {}
            if (std.fs.path.join(self.allocator, &.{ home_slice, ".config", "zenkai", "plugins" })) |dir_path| {
                defer self.allocator.free(dir_path);
                scanPluginDir(self, io, dir_path, plugin_filter);
            } else |_| {}
        }

        for (loader.standard_plugin_dirs) |dir_path| {
            scanPluginDir(self, io, dir_path, plugin_filter);
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

    pub fn handleSelect(self: *PluginManager, result: *const PluginResult) void {
        switch (result.result_type) {
            .NoReturn => return,
            .ExecCmd => {
                if (result.exec) |cmd| {
                    if (cmd.len > 0) {
                        utils.execute(cmd, self.allocator) catch |err| {
                            utils.log.info("plugin exec failed: {}", .{err});
                        };
                    }
                }
            },
        }

        const plugin = &self.plugins.items[result.plugin_index];
        if (plugin.hooks.contains(.on_open)) {
            _ = lua.lua_getglobal(plugin.state, "on_open");
            lua.lua_pushinteger(plugin.state, @as(i64, @intCast(result.id)));
            sandbox.callPluginMethod(plugin, 1, "open error");
        }

        if (g_pending_open_url) |url| {
            defer self.allocator.free(url);
            g_pending_open_url = null;

            if (url.len > 1023) return;

            const clip_cmd = self.clipboard_cmd orelse "";
            if (clip_cmd.len > 0) {
                var pipefd: [2]i32 = undefined;
                if (std.os.linux.pipe(&pipefd) != 0) return;

                const pid = std.os.linux.fork();
                if (std.os.linux.errno(pid) != .SUCCESS) {
                    _ = std.os.linux.close(pipefd[0]);
                    _ = std.os.linux.close(pipefd[1]);
                    return;
                }

                if (pid == 0) {
                    _ = std.os.linux.close(pipefd[1]);
                    _ = std.os.linux.dup2(pipefd[0], 0);
                    if (pipefd[0] != 0) _ = std.os.linux.close(pipefd[0]);

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
                    _ = std.os.linux.execve("/bin/sh", &argv, utils.environ);
                    std.os.linux.exit(1);
                }

                _ = std.os.linux.close(pipefd[0]);
                _ = std.os.linux.write(pipefd[1], url.ptr, url.len);
                _ = std.os.linux.close(pipefd[1]);
            } else {
                const handler = self.url_handler orelse "xdg-open";

                var handler_buf: [1024:0]u8 = undefined;
                var handler_c: [*:0]const u8 = undefined;
                if (std.mem.indexOfScalar(u8, handler, '/') != null) {
                    if (handler.len >= handler_buf.len) return;
                    @memcpy(handler_buf[0..handler.len], handler);
                    handler_buf[handler.len] = 0;
                    handler_c = @as([*:0]const u8, @ptrCast(&handler_buf));
                } else {
                    const written = std.fmt.bufPrint(&handler_buf, "/usr/bin/{s}", .{handler}) catch return;
                    handler_buf[written.len] = 0;
                    handler_c = @as([*:0]const u8, @ptrCast(&handler_buf));
                }

                var url_buf: [1024:0]u8 = undefined;
                if (url.len >= url_buf.len) return;
                @memcpy(url_buf[0..url.len], url);
                url_buf[url.len] = 0;

                const argv = [_:null]?[*:0]u8{
                    @constCast(handler_c),
                    @as([*:0]u8, @ptrCast(&url_buf)),
                    null,
                };

                const pid = std.os.linux.fork();
                if (std.os.linux.errno(pid) != .SUCCESS) return;
                if (pid == 0) {
                    _ = std.os.linux.execve(handler_c, &argv, utils.environ);
                    std.os.linux.exit(1);
                }

                const thread_data = self.allocator.create(ThreadData) catch return;
                thread_data.* = .{
                    .pid = @as(i32, @intCast(pid)),
                    .allocator = self.allocator,
                };

                const thread = std.Thread.spawn(.{}, reapChild, .{thread_data}) catch |err| {
                    self.allocator.destroy(thread_data);
                    var status: u32 = 0;
                    _ = std.os.linux.waitpid(@as(i32, @intCast(pid)), &status, 0);
                    utils.log.info("plugin url open reap thread failed: {}", .{err});
                    return;
                };
                thread.detach();
            }
        }
    }
};

const ThreadData = struct {
    pid: i32,
    allocator: std.mem.Allocator,
};

fn reapChild(data: *ThreadData) void {
    var status: u32 = 0;
    _ = std.os.linux.waitpid(data.pid, &status, 0);
    data.allocator.destroy(data);
}
