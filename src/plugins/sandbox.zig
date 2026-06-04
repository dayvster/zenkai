const std = @import("std");
const lua = @import("lua_capi");
const utils = @import("utils");
const types = @import("types.zig");

fn luaPrint(L: *lua.lua_State) callconv(.c) c_int {
    const argument_count = lua.lua_gettop(L);
    var buffer: [4096]u8 = undefined;
    var written: usize = 0;

    for (0..@as(usize, @intCast(argument_count))) |index| {
        const stack_index = @as(i32, @intCast(index + 1));
        _ = lua.lua_getglobal(L, "tostring");
        lua.lua_pushvalue(L, stack_index);

        if (lua.lua_pcall(L, 1, 1, 0) == lua.LUA_OK) {
            if (lua.lua_tostring(L, -1)) |raw_string| {
                const string_value = std.mem.sliceTo(raw_string, 0);
                if (index > 0 and written < buffer.len) {
                    buffer[written] = '\t';
                    written += 1;
                }
                const copy_length = @min(string_value.len, buffer.len - written);
                @memcpy(buffer[written..][0..copy_length], string_value[0..copy_length]);
                written += copy_length;
                lua.lua_pop(L, 1);
            }
        } else {
            lua.lua_pop(L, 1);
        }
    }

    if (written > 0) {
        utils.log.info("lua print: {s}", .{buffer[0..written]});
    }
    return 0;
}

pub fn setupSandbox(L: *lua.lua_State) void {
    const removed_globals = .{ "os", "io", "loadfile", "dofile", "require", "package", "debug" };
    inline for (removed_globals) |name| {
        lua.lua_pushnil(L);
        lua.lua_setglobal(L, @as([*:0]const u8, name));
    }

    lua.lua_pushcfunction(L, luaPrint);
    lua.lua_setglobal(L, "print");
}

fn instructionLimitHook(L: *lua.lua_State, _: *lua.lua_Debug) callconv(.c) void {
    lua.lua_sethook(L, null, 0, 0);
    _ = lua.lua_pushstring(L, "plugin exceeded instruction limit");
    _ = lua.lua_error(L);
}

fn errorHandler(L: *lua.lua_State) callconv(.c) c_int {
    _ = lua.lua_pushvalue(L, 1);
    return 1;
}

pub fn callPluginMethod(plugin: *types.Plugin, argument_count: c_int, error_label: []const u8) void {
    lua.lua_pushcfunction(plugin.state, errorHandler);
    lua.lua_insert(plugin.state, -(argument_count + 2));
    const error_handler_index = lua.lua_gettop(plugin.state) - argument_count - 1;

    lua.lua_sethook(plugin.state, instructionLimitHook, lua.LUA_MASKCOUNT, 50000);
    const result = lua.lua_pcall(plugin.state, argument_count, 0, error_handler_index);
    lua.lua_sethook(plugin.state, null, 0, 0);

    if (result != lua.LUA_OK) {
        const error_message = lua.lua_tostring(plugin.state, -1) orelse "unknown error";
        utils.log.info("plugin '{s}' {s}: {s}", .{ plugin.manifest.name, error_label, std.mem.sliceTo(error_message, 0) });
        lua.lua_pop(plugin.state, 2);
    } else {
        lua.lua_pop(plugin.state, 1);
    }
}
