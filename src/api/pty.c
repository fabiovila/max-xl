#include "api.h"

#include <SDL3/SDL.h>

#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/ioctl.h>

#if defined(__linux__) || defined(__ANDROID__)
  #define HAS_PTY 1
  #include <pty.h>
#elif defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__) || defined(__NetBSD__) || defined(__DragonFly__)
  #define HAS_PTY 1
  #include <util.h>
  #include <termios.h>
#endif

#define API_TYPE_PTY "Pty"

typedef struct {
  int master;
  pid_t pid;
  int exited;
  int code;
} pty_t;


#ifdef HAS_PTY

static pty_t* pty_check(lua_State *L, int idx) {
  return (pty_t*)luaL_checkudata(L, idx, API_TYPE_PTY);
}


// Static storage is unnecessary: the whole environment vector is built
// here in the parent (heap use is fine); the child only passes its
// pointer to execve(), which performs no allocation.
static char **build_child_env(const char *term_opt) {
  extern char **environ;
  size_t n = 0;
  if (environ) {
    while (environ[n]) n++;
  }
  // +2: possible new TERM slot and NULL terminator
  char **env = (char**)SDL_malloc(sizeof(char*) * (n + 2));
  if (!env)
    return NULL;
  size_t m = 0;
  for (size_t i = 0; i < n; i++) {
    if (strncmp(environ[i], "TERM=", 5) == 0)
      continue;
    env[m++] = environ[i];
  }
  // TERM always comes from the pty layer so children see xterm-256color
  // (or the requested override) regardless of the launcher environment.
  static char term_buf[256];
  snprintf(term_buf, sizeof(term_buf), "TERM=%s", term_opt ? term_opt : "xterm-256color");
  env[m++] = term_buf;
  env[m] = NULL;
  return env;
}

// Parent-side PATH lookup (may allocate freely; the child never does).
static char *resolve_in_path(const char *cmd) {
  if (strchr(cmd, '/')) {
    if (access(cmd, X_OK) == 0)
      return SDL_strdup(cmd);
    return NULL;
  }
  const char *path = getenv("PATH");
  if (!path || !*path)
    path = "/bin:/usr/bin";
  const char *p = path;
  while (1) {
    const char *end = strchr(p, ':');
    size_t dirlen = end ? (size_t)(end - p) : strlen(p);
    size_t need = (dirlen ? dirlen + 1 : 0) + strlen(cmd) + 1;
    char *full = (char*)SDL_malloc(need);
    if (!full)
      return NULL;
    if (dirlen) {
      memcpy(full, p, dirlen);
      full[dirlen] = '/';
      strcpy(full + dirlen + 1, cmd);
    } else {
      strcpy(full, cmd);
    }
    if (access(full, X_OK) == 0)
      return full;
    SDL_free(full);
    if (!end)
      break;
    p = end + 1;
  }
  return NULL;
}

extern char **environ;


// pty.start(cmd_table, opts?) -> handle
// opts: { cwd = string, cols = int, rows = int, term = string }
// Spawns cmd[1] with a controlling pty. Master side is non-blocking.
//
// NOTE: max-xl is multithreaded, so fork() inherits a possibly
// inconsistent heap. The child therefore never touches the heap:
// the executable and the environment vector are prepared here in
// the parent; the child only performs syscalls (chdir, execve).
static int f_start(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  int argc = (int)luaL_len(L, 1);
  if (argc < 1)
    return luaL_error(L, "pty.start needs a non-empty command table");

  const char *cwd_opt = NULL, *term_opt = NULL;
  int cols = 80, rows = 24;
  if (lua_istable(L, 2)) {
    lua_getfield(L, 2, "cwd");  if (lua_isstring(L, -1)) cwd_opt = lua_tostring(L, -1);
    lua_getfield(L, 2, "term"); if (lua_isstring(L, -1)) term_opt = lua_tostring(L, -1);
    lua_getfield(L, 2, "cols"); if (lua_isnumber(L, -1)) cols = (int)lua_tointeger(L, -1);
    lua_getfield(L, 2, "rows"); if (lua_isnumber(L, -1)) rows = (int)lua_tointeger(L, -1);
    lua_pop(L, 3);
  }
  if (cols < 1) cols = 1;
  if (rows < 1) rows = 1;

  // parent-owned copies (no Lua lifetime concerns across fork)
  char *cwd = cwd_opt ? SDL_strdup(cwd_opt) : NULL;
  char **argv = (char**)SDL_malloc(sizeof(char*) * (argc + 1));
  int ok = (argv != NULL);
  int i;
  for (i = 0; ok && i < argc; i++) {
    lua_rawgeti(L, 1, i + 1);
    const char *s = lua_tostring(L, -1);
    argv[i] = s ? SDL_strdup(s) : NULL;
    if (!argv[i])
      ok = 0;
    lua_pop(L, 1);
  }
  argv[ok ? argc : 0] = NULL;
  char *abspath = ok ? resolve_in_path(argv[0]) : NULL;
  if (!ok || !abspath) {
    for (int j = 0; j < i; j++) SDL_free(argv[j]);
    SDL_free(argv);
    SDL_free(cwd);
    return luaL_error(L, "pty.start: command not found");
  }
  char **child_env = build_child_env(term_opt);
  if (!child_env) {
    for (int j = 0; j < i; j++) SDL_free(argv[j]);
    SDL_free(argv);
    SDL_free(cwd);
    SDL_free(abspath);
    return luaL_error(L, "out of memory");
  }

  struct winsize ws;
  memset(&ws, 0, sizeof(ws));
  ws.ws_col = (unsigned short)cols;
  ws.ws_row = (unsigned short)rows;

  int master = -1;
  pid_t pid = forkpty(&master, NULL, NULL, &ws);

  if (pid == 0) {
    // child: heap is off-limits (see NOTE above); syscalls only
    if (cwd && chdir(cwd) != 0)
      _exit(126);
    execve(abspath, argv, child_env);
    _exit(127);
  }

  // parent cleanup (only the parent reaches here)
  for (int j = 0; j < argc; j++) SDL_free(argv[j]);
  SDL_free(argv);
  SDL_free(abspath);
  SDL_free(cwd);
  SDL_free(child_env);

  if (pid < 0)
    return luaL_error(L, "forkpty failed: %s", strerror(errno));

  int flags = fcntl(master, F_GETFL, 0);
  if (flags >= 0)
    fcntl(master, F_SETFL, flags | O_NONBLOCK);

  pty_t *self = (pty_t*)lua_newuserdata(L, sizeof(pty_t));
  self->master = master;
  self->pid = pid;
  self->exited = 0;
  self->code = 0;
  luaL_setmetatable(L, API_TYPE_PTY);
  return 1;
}


static int poll_child(pty_t *self) {
  if (self->exited || self->pid <= 0)
    return 0;
  int status = 0;
  pid_t r = waitpid(self->pid, &status, WNOHANG);
  if (r == self->pid) {
    self->exited = 1;
    if (WIFEXITED(status))
      self->code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status))
      self->code = 128 + WTERMSIG(status);
    else
      self->code = -1;
    return 0;
  }
  return r == 0;
}


// read([maxbytes]) -> string | nil
// Returns "" when no data is available, nil on EOF.
static int f_read(lua_State *L) {
  pty_t *self = pty_check(L, 1);
  size_t want = (size_t)luaL_optinteger(L, 2, 4096);
  if (want < 1) want = 1;
  if (want > 65536) want = 65536;
  if (self->master < 0) {
    lua_pushnil(L);
    return 1;
  }
  char *buf = (char*)SDL_malloc(want);
  if (!buf)
    return luaL_error(L, "out of memory");
  ssize_t n = read(self->master, buf, want);
  if (n > 0) {
    lua_pushlstring(L, buf, (size_t)n);
  } else if (n == 0) {
    lua_pushnil(L); // EOF
  } else if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
    lua_pushliteral(L, ""); // no data right now
  } else {
    lua_pushnil(L); // EIO and friends: pty is gone
  }
  SDL_free(buf);
  return 1;
}


// write(data) -> bytes written
static int f_write(lua_State *L) {
  pty_t *self = pty_check(L, 1);
  size_t len = 0;
  const char *data = luaL_checklstring(L, 2, &len);
  size_t sent = 0;
  while (sent < len && self->master >= 0) {
    ssize_t n = write(self->master, data + sent, len - sent);
    if (n > 0) {
      sent += (size_t)n;
    } else if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) {
      break;
    } else {
      break;
    }
  }
  lua_pushinteger(L, (lua_Integer)sent);
  return 1;
}


// resize(cols, rows) -> true; also notifies the foreground group
static int f_resize(lua_State *L) {
  pty_t *self = pty_check(L, 1);
  int cols = (int)luaL_checkinteger(L, 2);
  int rows = (int)luaL_checkinteger(L, 3);
  if (cols < 1) cols = 1;
  if (rows < 1) rows = 1;
  if (self->master >= 0) {
    struct winsize ws;
    memset(&ws, 0, sizeof(ws));
    ws.ws_col = (unsigned short)cols;
    ws.ws_row = (unsigned short)rows;
    ioctl(self->master, TIOCSWINSZ, &ws);
  }
  if (self->pid > 0 && !self->exited)
    kill(self->pid, SIGWINCH);
  lua_pushboolean(L, 1);
  return 1;
}


// running() -> bool (also reaps the child when it exits)
static int f_running(lua_State *L) {
  pty_t *self = pty_check(L, 1);
  lua_pushboolean(L, poll_child(self));
  return 1;
}


// returncode() -> int | nil
static int f_returncode(lua_State *L) {
  pty_t *self = pty_check(L, 1);
  poll_child(self);
  if (self->exited)
    lua_pushinteger(L, self->code);
  else
    lua_pushnil(L);
  return 1;
}


static int f_pid(lua_State *L) {
  pty_t *self = pty_check(L, 1);
  lua_pushinteger(L, self->pid);
  return 1;
}


static int f_kill(lua_State *L) {
  pty_t *self = pty_check(L, 1);
  if (self->pid > 0 && !self->exited)
    kill(self->pid, SIGKILL);
  lua_pushboolean(L, 1);
  return 1;
}


static void close_master(pty_t *self) {
  if (self->master >= 0) {
    // closing the master hangs up the slave side (SIGHUP)
    close(self->master);
    self->master = -1;
  }
  poll_child(self);
}


static int f_close(lua_State *L) {
  close_master(pty_check(L, 1));
  lua_pushboolean(L, 1);
  return 1;
}


static int f_gc(lua_State *L) {
  close_master(pty_check(L, 1));
  return 0;
}


static const luaL_Reg methods[] = {
  { "read",       f_read },
  { "write",      f_write },
  { "resize",     f_resize },
  { "running",    f_running },
  { "returncode", f_returncode },
  { "pid",        f_pid },
  { "kill",       f_kill },
  { "close",      f_close },
  { "__gc",       f_gc },
  { NULL, NULL }
};

#else // no pty support on this platform

static int f_start(lua_State *L) {
  (void)L;
  return luaL_error(L, "pty is not supported on this platform");
}

static const luaL_Reg methods[] = {
  { NULL, NULL }
};

#endif


static const luaL_Reg lib[] = {
  { "start", f_start },
  { NULL,    NULL }
};


int luaopen_pty(lua_State *L) {
#ifdef HAS_PTY
  luaL_newmetatable(L, API_TYPE_PTY);
  luaL_setfuncs(L, methods, 0);
  lua_pushvalue(L, -1);
  lua_setfield(L, -2, "__index");
#endif
  luaL_newlib(L, lib);
  return 1;
}
