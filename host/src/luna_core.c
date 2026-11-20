/* luna_core: small libc-only native helpers for luna-host. */
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

#include "lua.h"
#include "lauxlib.h"

static int push_err(lua_State *L, const char *msg) {
  lua_pushnil(L);
  lua_pushstring(L, msg);
  return 2;
}

static int push_errno(lua_State *L) {
  int e = errno;
  lua_pushnil(L);
  lua_pushstring(L, strerror(e));
  lua_pushinteger(L, e);
  return 3;
}

static double now_clock(clockid_t c) {
  struct timespec ts;
  clock_gettime(c, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

static void set_nonblock(int fd) {
  int fl = fcntl(fd, F_GETFL, 0);
  if (fl >= 0) fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

/* tcp_connect(port [, timeout [, host]]) -> fd | nil, err */
static int l_tcp_connect(lua_State *L) {
  lua_Integer port = luaL_checkinteger(L, 1);
  double timeout = luaL_optnumber(L, 2, 5.0);
  const char *host = luaL_optstring(L, 3, "127.0.0.1");
  struct sockaddr_in a;
  int fd, one = 1;
  if (port < 1 || port > 65535) return push_err(L, "bad port");
  memset(&a, 0, sizeof a);
  a.sin_family = AF_INET;
  a.sin_port = htons((unsigned short)port);
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) return push_err(L, "bad address");
  fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return push_errno(L);
  set_nonblock(fd);
  setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
  if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
    if (errno != EINPROGRESS) {
      int e = errno;
      close(fd);
      errno = e;
      return push_errno(L);
    }
    {
      fd_set w;
      struct timeval tv;
      int r, err = 0;
      socklen_t el = sizeof err;
      FD_ZERO(&w);
      FD_SET(fd, &w);
      tv.tv_sec = (time_t)timeout;
      tv.tv_usec = (suseconds_t)((timeout - (double)tv.tv_sec) * 1e6);
      r = select(fd + 1, NULL, &w, NULL, &tv);
      if (r <= 0) {
        close(fd);
        return push_err(L, r == 0 ? "timeout" : strerror(errno));
      }
      getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
      if (err) {
        close(fd);
        return push_err(L, strerror(err));
      }
    }
  }
  lua_pushinteger(L, fd);
  return 1;
}

/* unix_connect(path [, timeout]) -> fd | nil, err */
static int l_unix_connect(lua_State *L) {
  size_t plen;
  const char *path = luaL_checklstring(L, 1, &plen);
  double timeout = luaL_optnumber(L, 2, 5.0);
  struct sockaddr_un a;
  int fd;
  if (plen == 0 || plen >= sizeof a.sun_path) return push_err(L, "bad path");
  memset(&a, 0, sizeof a);
  a.sun_family = AF_UNIX;
  memcpy(a.sun_path, path, plen);
  fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
  if (fd < 0) return push_errno(L);
  set_nonblock(fd);
  if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) {
    if (errno != EINPROGRESS && errno != EAGAIN) {
      int e = errno;
      close(fd);
      errno = e;
      return push_errno(L);
    }
    {
      fd_set w;
      struct timeval tv;
      int r, err = 0;
      socklen_t el = sizeof err;
      FD_ZERO(&w);
      FD_SET(fd, &w);
      tv.tv_sec = (time_t)timeout;
      tv.tv_usec = (suseconds_t)((timeout - (double)tv.tv_sec) * 1e6);
      r = select(fd + 1, NULL, &w, NULL, &tv);
      if (r <= 0) {
        close(fd);
        return push_err(L, r == 0 ? "timeout" : strerror(errno));
      }
      getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &el);
      if (err) {
        close(fd);
        return push_err(L, strerror(err));
      }
    }
  }
  lua_pushinteger(L, fd);
  return 1;
}

/* tcp_send(fd, data [, i]) -> bytes sent | nil,'timeout' | nil,'closed' */
static int l_tcp_send(lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  size_t len, i = (size_t)luaL_optinteger(L, 3, 1);
  const char *s = luaL_checklstring(L, 2, &len);
  ssize_t n;
  if (i < 1) i = 1;
  if (i - 1 > len) return push_err(L, "bad offset");
  n = send(fd, s + i - 1, len - (i - 1), MSG_NOSIGNAL);
  if (n < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return push_err(L, "timeout");
    return push_err(L, "closed");
  }
  lua_pushinteger(L, n);
  return 1;
}

/* tcp_recv(fd, n) -> data | nil,'timeout' | nil,'closed' */
static int l_tcp_recv(lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  lua_Integer n = luaL_checkinteger(L, 2);
  luaL_Buffer b;
  char *p;
  ssize_t r;
  if (n < 1) n = 1;
  if (n > 1 << 24) n = 1 << 24;
  p = luaL_buffinitsize(L, &b, (size_t)n);
  r = recv(fd, p, (size_t)n, 0);
  if (r < 0) {
    if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) return push_err(L, "timeout");
    return push_err(L, "closed");
  }
  if (r == 0) return push_err(L, "closed");
  luaL_pushresultsize(&b, (size_t)r);
  return 1;
}

static int l_close(lua_State *L) {
  int fd = (int)luaL_checkinteger(L, 1);
  lua_pushboolean(L, close(fd) == 0);
  return 1;
}

static int fill_set(lua_State *L, int idx, fd_set *s, int *maxfd) {
  FD_ZERO(s);
  if (lua_isnoneornil(L, idx)) return 0;
  luaL_checktype(L, idx, LUA_TTABLE);
  lua_Integer n = luaL_len(L, idx), i;
  for (i = 1; i <= n; i++) {
    int fd;
    lua_geti(L, idx, i);
    fd = (int)luaL_checkinteger(L, -1);
    lua_pop(L, 1);
    if (fd < 0 || fd >= FD_SETSIZE) return luaL_error(L, "fd out of range");
    FD_SET(fd, s);
    if (fd > *maxfd) *maxfd = fd;
  }
  return 0;
}

static void collect(lua_State *L, int idx, fd_set *s) {
  lua_Integer n = lua_isnoneornil(L, idx) ? 0 : luaL_len(L, idx), i, k = 1;
  lua_newtable(L);
  for (i = 1; i <= n; i++) {
    int fd;
    lua_geti(L, idx, i);
    fd = (int)lua_tointeger(L, -1);
    lua_pop(L, 1);
    if (FD_ISSET(fd, s)) {
      lua_pushinteger(L, fd);
      lua_seti(L, -2, k++);
    }
  }
}

/* select(read_fds, write_fds, timeout) -> ready_r, ready_w | nil,'timeout' */
static int l_select(lua_State *L) {
  fd_set r, w;
  int maxfd = -1, n;
  struct timeval tv, *tp = NULL;
  fill_set(L, 1, &r, &maxfd);
  fill_set(L, 2, &w, &maxfd);
  if (!lua_isnoneornil(L, 3)) {
    double t = luaL_checknumber(L, 3);
    if (t < 0) t = 0;
    tv.tv_sec = (time_t)t;
    tv.tv_usec = (suseconds_t)((t - (double)tv.tv_sec) * 1e6);
    tp = &tv;
  }
  n = select(maxfd + 1, &r, &w, NULL, tp);
  if (n < 0) {
    if (errno == EINTR) return push_err(L, "timeout");
    return push_errno(L);
  }
  if (n == 0) return push_err(L, "timeout");
  collect(L, 1, &r);
  collect(L, 2, &w);
  return 2;
}

static int l_sleep(lua_State *L) {
  double t = luaL_checknumber(L, 1);
  struct timespec ts;
  if (t <= 0) return 0;
  ts.tv_sec = (time_t)t;
  ts.tv_nsec = (long)((t - (double)ts.tv_sec) * 1e9);
  while (nanosleep(&ts, &ts) < 0 && errno == EINTR) {}
  return 0;
}

static int l_gettime(lua_State *L) {
  lua_pushnumber(L, now_clock(CLOCK_REALTIME));
  return 1;
}

static int l_monotonic(lua_State *L) {
  lua_pushnumber(L, now_clock(CLOCK_MONOTONIC));
  return 1;
}

static int l_urandom(lua_State *L) {
  lua_Integer n = luaL_checkinteger(L, 1);
  luaL_Buffer b;
  char *p;
  size_t got = 0;
  int fd;
  if (n < 0 || n > 1 << 20) return luaL_error(L, "bad length");
  p = luaL_buffinitsize(L, &b, (size_t)n);
  fd = open("/dev/urandom", O_RDONLY | O_CLOEXEC);
  if (fd < 0) return push_errno(L);
  while (got < (size_t)n) {
    ssize_t r = read(fd, p + got, (size_t)n - got);
    if (r <= 0) {
      if (r < 0 && errno == EINTR) continue;
      close(fd);
      return push_err(L, "read failed");
    }
    got += (size_t)r;
  }
  close(fd);
  luaL_pushresultsize(&b, got);
  return 1;
}

static const char *mode_name(mode_t m) {
  if (S_ISREG(m)) return "file";
  if (S_ISDIR(m)) return "directory";
  if (S_ISLNK(m)) return "link";
  if (S_ISSOCK(m)) return "socket";
  if (S_ISFIFO(m)) return "named pipe";
  if (S_ISCHR(m)) return "char device";
  if (S_ISBLK(m)) return "block device";
  return "other";
}

/* stat(path [, nofollow]) -> {mode,size,modification,access,change,perm,uid,nlink} | nil,err */
static int l_stat(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  struct stat st;
  int r = lua_toboolean(L, 2) ? lstat(path, &st) : stat(path, &st);
  if (r < 0) return push_errno(L);
  lua_createtable(L, 0, 8);
  lua_pushstring(L, mode_name(st.st_mode));
  lua_setfield(L, -2, "mode");
  lua_pushinteger(L, (lua_Integer)st.st_size);
  lua_setfield(L, -2, "size");
  lua_pushinteger(L, (lua_Integer)st.st_mtime);
  lua_setfield(L, -2, "modification");
  lua_pushinteger(L, (lua_Integer)st.st_atime);
  lua_setfield(L, -2, "access");
  lua_pushinteger(L, (lua_Integer)st.st_ctime);
  lua_setfield(L, -2, "change");
  lua_pushinteger(L, (lua_Integer)(st.st_mode & 07777));
  lua_setfield(L, -2, "perm");
  lua_pushinteger(L, (lua_Integer)st.st_uid);
  lua_setfield(L, -2, "uid");
  lua_pushinteger(L, (lua_Integer)st.st_nlink);
  lua_setfield(L, -2, "nlink");
  return 1;
}

/* listdir(path) -> array of names (no . / ..) | nil,err */
static int l_listdir(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);
  DIR *d = opendir(path);
  struct dirent *e;
  lua_Integer i = 1;
  if (!d) return push_errno(L);
  lua_newtable(L);
  while ((e = readdir(d)) != NULL) {
    if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
    lua_pushstring(L, e->d_name);
    lua_seti(L, -2, i++);
  }
  closedir(d);
  return 1;
}

static int bool_result(lua_State *L, int r) {
  if (r < 0) return push_errno(L);
  lua_pushboolean(L, 1);
  return 1;
}

static int l_mkdir(lua_State *L) {
  return bool_result(L, mkdir(luaL_checkstring(L, 1), (mode_t)luaL_optinteger(L, 2, 0777)));
}
static int l_rmdir(lua_State *L) { return bool_result(L, rmdir(luaL_checkstring(L, 1))); }
static int l_remove(lua_State *L) { return bool_result(L, remove(luaL_checkstring(L, 1))); }
static int l_rename(lua_State *L) {
  return bool_result(L, rename(luaL_checkstring(L, 1), luaL_checkstring(L, 2)));
}
static int l_chmod(lua_State *L) {
  return bool_result(L, chmod(luaL_checkstring(L, 1), (mode_t)luaL_checkinteger(L, 2)));
}

static int l_getpid(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)getpid());
  return 1;
}

static int l_readlink(lua_State *L) {
  char buf[4096];
  ssize_t n = readlink(luaL_checkstring(L, 1), buf, sizeof buf);
  if (n < 0) return push_errno(L);
  lua_pushlstring(L, buf, (size_t)n);
  return 1;
}

/* umask(mask) -> previous mask */
static int l_umask(lua_State *L) {
  lua_pushinteger(L, (lua_Integer)umask((mode_t)luaL_checkinteger(L, 1)));
  return 1;
}

static int l_getcwd(lua_State *L) {
  char buf[4096];
  if (!getcwd(buf, sizeof buf)) return push_errno(L);
  lua_pushstring(L, buf);
  return 1;
}

static const luaL_Reg funcs[] = {
  {"tcp_connect", l_tcp_connect}, {"unix_connect", l_unix_connect}, {"tcp_send", l_tcp_send}, {"tcp_recv", l_tcp_recv},
  {"close", l_close}, {"select", l_select}, {"sleep", l_sleep},
  {"gettime", l_gettime}, {"monotonic", l_monotonic}, {"urandom", l_urandom},
  {"stat", l_stat}, {"listdir", l_listdir}, {"mkdir", l_mkdir}, {"rmdir", l_rmdir},
  {"remove", l_remove}, {"rename", l_rename}, {"getpid", l_getpid},
  {"readlink", l_readlink}, {"chmod", l_chmod}, {"umask", l_umask}, {"getcwd", l_getcwd},
  {NULL, NULL}};

int luaopen_luna_core(lua_State *L) {
  signal(SIGPIPE, SIG_IGN);
  luaL_newlib(L, funcs);
  return 1;
}
