const std = @import("std");

pub const lua_State = opaque {};

pub const lua_CFunction = *const fn (L: *lua_State) callconv(.c) c_int;
pub const lua_KContext = isize;
pub const lua_KFunction = *const fn (L: *lua_State, status: c_int, ctx: lua_KContext) callconv(.c) c_int;
pub const lua_Hook = ?*const fn (L: *lua_State, ar: *lua_Debug) callconv(.c) void;

pub const lua_Debug = extern struct {
    event: c_int,
    name: ?[*:0]const u8,
    namewhat: ?[*:0]const u8,
    what: ?[*:0]const u8,
    source: ?[*:0]const u8,
    currentline: c_int,
    linedefined: c_int,
    lastlinedefined: c_int,
    nups: u8,
    nparams: u8,
    isvararg: u8,
    istailcall: u8,
    short_src: [60]u8,
    i_ci: c_int,
};

pub const LUA_OK = 0;
pub const LUA_YIELD = 1;
pub const LUA_ERRRUN = 2;
pub const LUA_ERRSYNTAX = 3;
pub const LUA_ERRMEM = 4;
pub const LUA_ERRERR = 5;

pub const LUA_TNONE = -1;
pub const LUA_TNIL = 0;
pub const LUA_TBOOLEAN = 1;
pub const LUA_TNUMBER = 3;
pub const LUA_TSTRING = 4;
pub const LUA_TTABLE = 5;
pub const LUA_TFUNCTION = 6;

pub const LUA_MULTRET = -1;

pub const LUA_HOOKCOUNT = 1;
pub const LUA_HOOKLINE = 2;

extern "c" fn luaL_newstate() ?*lua_State;
extern "c" fn lua_close(L: *lua_State) void;
extern "c" fn luaL_openselectedlibs(L: *lua_State, libs: c_uint, nlibs: c_int) void;
extern "c" fn luaL_loadstring(L: *lua_State, s: [*:0]const u8) c_int;
extern "c" fn lua_pcallk(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int, ctx: lua_KContext, k: lua_KFunction) c_int;
extern "c" fn lua_getglobal(L: *lua_State, name: [*:0]const u8) c_int;
extern "c" fn lua_setglobal(L: *lua_State, name: [*:0]const u8) void;
extern "c" fn lua_pushcclosure(L: *lua_State, func: lua_CFunction, n: c_int) void;
extern "c" fn lua_pushstring(L: *lua_State, s: [*:0]const u8) ?[*:0]const u8;
extern "c" fn lua_pushnumber(L: *lua_State, n: f64) void;
extern "c" fn lua_pushboolean(L: *lua_State, b: c_int) void;
extern "c" fn lua_pushinteger(L: *lua_State, n: i64) void;
extern "c" fn lua_pushnil(L: *lua_State) void;
extern "c" fn lua_tolstring(L: *lua_State, idx: c_int, len: ?*usize) ?[*:0]const u8;
extern "c" fn lua_tonumberx(L: *lua_State, idx: c_int, isnum: ?*c_int) f64;
extern "c" fn lua_tointegerx(L: *lua_State, idx: c_int, isnum: ?*c_int) i64;
extern "c" fn lua_toboolean(L: *lua_State, idx: c_int) c_int;
extern "c" fn lua_type(L: *lua_State, idx: c_int) c_int;
extern "c" fn lua_typename(L: *lua_State, tp: c_int) [*:0]const u8;
extern "c" fn lua_settop(L: *lua_State, idx: c_int) void;
extern "c" fn lua_getfield(L: *lua_State, idx: c_int, k: [*:0]const u8) c_int;
extern "c" fn lua_setfield(L: *lua_State, idx: c_int, k: [*:0]const u8) void;
extern "c" fn lua_createtable(L: *lua_State, narr: c_int, nrec: c_int) void;
extern "c" fn lua_rawseti(L: *lua_State, idx: c_int, n: i64) void;
extern "c" fn lua_rawgeti(L: *lua_State, idx: c_int, n: i64) c_int;
extern "c" fn lua_next(L: *lua_State, idx: c_int) c_int;
extern "c" fn lua_pushvalue(L: *lua_State, idx: c_int) void;
extern "c" fn lua_copy(L: *lua_State, fromidx: c_int, toidx: c_int) void;
extern "c" fn lua_len(L: *lua_State, idx: c_int) void;
extern "c" fn lua_sethook(L: *lua_State, func: lua_Hook, mask: c_int, count: c_int) void;
extern "c" fn lua_gettop(L: *lua_State) c_int;
extern "c" fn luaL_error(L: *lua_State, fmt: [*:0]const u8, ...) c_int;

pub fn luaL_newstateOrPanic() *lua_State {
    return luaL_newstate() orelse @panic("luaL_newstate returned null");
}

pub fn luaL_openlibs(L: *lua_State) void {
    luaL_openselectedlibs(L, ~@as(c_uint, 0), 0);
}

pub fn lua_pcall(L: *lua_State, nargs: c_int, nresults: c_int, errfunc: c_int) c_int {
    return lua_pcallk(L, nargs, nresults, errfunc, 0, null);
}

pub fn lua_tonumber(L: *lua_State, idx: c_int) f64 {
    return lua_tonumberx(L, idx, null);
}

pub fn lua_tointeger(L: *lua_State, idx: c_int) i64 {
    return lua_tointegerx(L, idx, null);
}

pub fn lua_tostring(L: *lua_State, idx: c_int) ?[*:0]const u8 {
    return lua_tolstring(L, idx, null);
}

pub fn lua_pop(L: *lua_State, n: c_int) void {
    lua_settop(L, -(n) - 1);
}

pub fn lua_newtable(L: *lua_State) void {
    lua_createtable(L, 0, 0);
}

pub fn lua_pushcfunction(L: *lua_State, func: lua_CFunction) void {
    lua_pushcclosure(L, func, 0);
}

pub fn lua_isfunction(L: *lua_State, idx: c_int) bool {
    return lua_type(L, idx) == LUA_TFUNCTION;
}
