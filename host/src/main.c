/* luna-host: embeds Lua, preloads luna_core, runs luna.boot. */
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

int luaopen_luna_core(lua_State *L);

static int msgh(lua_State *L) {
  const char *m = lua_tostring(L, 1);
  if (m == NULL) {
    if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) return 1;
    m = lua_pushfstring(L, "(error object is a %s value)", luaL_typename(L, 1));
  }
  luaL_traceback(L, L, m, 1);
  return 1;
}

static void exe_dir(char *out, size_t n) {
  char buf[PATH_MAX];
  ssize_t r = readlink("/proc/self/exe", buf, sizeof buf - 1);
  char *s;
  if (r <= 0) {
    snprintf(out, n, ".");
    return;
  }
  buf[r] = 0;
  s = strrchr(buf, '/');
  if (s && s != buf) *s = 0;
  else if (s) s[1] = 0;
  snprintf(out, n, "%s", buf);
}

static int has_boot(const char *dir) {
  char f[3 * PATH_MAX];
  if (snprintf(f, sizeof f, "%s/luna/boot.lua", dir) >= (int)sizeof f) return 0;
  return access(f, R_OK) == 0;
}

static void setup_path(lua_State *L) {
  char dir[2 * PATH_MAX];
  char path[8 * PATH_MAX];
  const char *env = getenv("LUNA_LUA_DIR");
  if (env && *env) snprintf(dir, sizeof dir, "%s", env);
  else {
    char ed[PATH_MAX];
    char cand[3][2 * PATH_MAX];
    int i;
    exe_dir(ed, sizeof ed);
    snprintf(cand[0], sizeof cand[0], "%s/lua", ed);
    snprintf(cand[1], sizeof cand[1], "%s/../lua", ed);
    snprintf(cand[2], sizeof cand[2], "%s/../share/luna-host/lua", ed);
    snprintf(dir, sizeof dir, "%s", cand[0]);
    for (i = 0; i < 3; i++) {
      if (has_boot(cand[i])) {
        strcpy(dir, cand[i]); /* same size buffers */
        break;
      }
    }
  }
  snprintf(path, sizeof path, "%s/?.lua;%s/?/init.lua", dir, dir);
  lua_getglobal(L, "package");
  lua_pushstring(L, path);
  lua_setfield(L, -2, "path");
  /* no C module loading: drop the cpath/all-in-one searchers (avoids empty templates) */
  lua_getfield(L, -1, "searchers");
  lua_pushnil(L);
  lua_seti(L, -2, 4);
  lua_pushnil(L);
  lua_seti(L, -2, 3);
  lua_pop(L, 2);
}

static void push_args(lua_State *L, int argc, char **argv, int from) {
  int i;
  lua_createtable(L, argc - from, 1);
  lua_pushstring(L, argv[0]);
  lua_seti(L, -2, 0);
  for (i = from; i < argc; i++) {
    lua_pushstring(L, argv[i]);
    lua_seti(L, -2, i - from + 1);
  }
}

static int report(lua_State *L, int st) {
  if (st != LUA_OK) {
    const char *m = lua_tostring(L, -1);
    fprintf(stderr, "luna-host: %s\n", m ? m : "(unknown error)");
    lua_pop(L, 1);
    return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  lua_State *L = luaL_newstate();
  int status, rc = 0, base;
  if (!L) {
    fprintf(stderr, "luna-host: cannot create Lua state\n");
    return 1;
  }
  luaL_openlibs(L);
  luaL_requiref(L, "luna_core", luaopen_luna_core, 1);
  lua_pop(L, 1);
  setup_path(L);

  lua_pushcfunction(L, msgh);
  base = lua_gettop(L);

  if (argc >= 3 && strcmp(argv[1], "--eval") == 0) {
    push_args(L, argc, argv, 3);
    lua_pushstring(L, argv[2]);
    lua_seti(L, -2, 0);
    lua_setglobal(L, "arg");
    if (luaL_loadfile(L, argv[2]) != LUA_OK) return report(L, LUA_ERRSYNTAX), lua_close(L), 1;
    {
      int i, nargs = 0;
      for (i = 3; i < argc; i++) {
        lua_pushstring(L, argv[i]);
        nargs++;
      }
      status = lua_pcall(L, nargs, 0, base);
    }
    rc = report(L, status);
  } else {
    lua_getglobal(L, "require");
    lua_pushstring(L, "luna.boot");
    status = lua_pcall(L, 1, 1, base);
    if (status != LUA_OK) {
      rc = report(L, status);
    } else {
      lua_getfield(L, -1, "main");
      if (!lua_isfunction(L, -1)) {
        fprintf(stderr, "luna-host: luna.boot has no main()\n");
        rc = 1;
      } else {
        push_args(L, argc, argv, 1);
        status = lua_pcall(L, 1, 1, base);
        if (status != LUA_OK) rc = report(L, status);
        else if (lua_isinteger(L, -1)) rc = (int)lua_tointeger(L, -1);
        else if (lua_isboolean(L, -1)) rc = lua_toboolean(L, -1) ? 0 : 1;
        else rc = 0;
      }
    }
  }
  fflush(NULL);
  lua_close(L);
  return rc;
}
