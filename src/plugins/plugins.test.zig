const std = @import("std");
const lua = @import("lua_capi");

test "lua_works" {
    const L = lua.luaL_newstateOrPanic();
    defer lua.lua_close(L);
    lua.luaL_openlibs(L);
    const load_ok = lua.luaL_loadstring(L, "return 1+1") == lua.LUA_OK;
    try std.testing.expect(load_ok);
    const call_ok = lua.lua_pcall(L, 0, 1, 0) == lua.LUA_OK;
    try std.testing.expect(call_ok);
    const value = lua.lua_tonumber(L, -1);
    try std.testing.expectEqual(@as(f64, 2.0), value);
    lua.lua_pop(L, 1);
}
