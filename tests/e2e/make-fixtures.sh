#!/bin/bash
# Rebuilds the e2e fixtures from scratch (idempotent).
# Usage: tests/e2e/make-fixtures.sh <fixtures-root>
set -e
FIX="${1:?fixtures root required}"

# lxtest project ----------------------------------------------------------
mkdir -p "$FIX/lxtest/.max-xl"
printf 'hello foo world\nnothing here\nanother foo line\nFOO uppercase\nfoobar glued\n' > "$FIX/lxtest/notes.txt"
printf 'local x = \n' > "$FIX/lxtest/zz-bad.lua"
cat > "$FIX/lxtest/.max-xl/init.lua" <<'LUAEOF'
local fp = io.open(os.getenv("E2E_MARKER") or "/tmp/maxxl-marker.log", "a")
if fp then fp:write("litexxl loaded for " .. tostring(...) .. "\n") fp:close() end
LUAEOF

# gitrepo project (pristine dirty state) ------------------------------------
rm -rf "$FIX/gitrepo"
mkdir -p "$FIX/gitrepo"
cd "$FIX/gitrepo"
git init -q -b main .
git config user.email t@t.t
git config user.name t
git config commit.gpgsign false
printf 'line one\nline two\n' > f.txt
git add f.txt
git commit -qm init
printf 'line one\nline two changed\n' > f.txt
printf 'new file\n' > u.txt
mkdir -p "$FIX/lxtest2"
git status --porcelain=v1 -uall

# gdb fixtures --------------------------------------------------------------
# Native program used by the GDB/MI session test.
if command -v cc >/dev/null 2>&1; then
  mkdir -p "$FIX/gdb"
  cat > "$FIX/gdb/prog.c" <<'CEOF'
#include <stdio.h>

int add(int a, int b) {
  int s = a + b;
  return s;
}

int main(void) {
  printf("%d\n", add(2, 3));
  return 0;
}
CEOF
  cc -g -O0 -o "$FIX/gdb/prog" "$FIX/gdb/prog.c"
fi

# Build-task fixtures (compiler diagnostics) --------------------------------
if command -v cc >/dev/null 2>&1; then
  mkdir -p "$FIX/build"
  cat > "$FIX/build/bad.c" <<'CEOF'
int helper(void) { return missing_symbol; }
int main(void) { return helper(); }
CEOF
  cat > "$FIX/build/good.c" <<'CEOF'
int main(void) { return 0; }
CEOF
fi

# ARM freestanding program used by the remote (QEMU gdbstub) test.
if command -v arm-none-eabi-gcc >/dev/null 2>&1; then
  mkdir -p "$FIX/gdbarm"
  cat > "$FIX/gdbarm/prog.c" <<'CEOF'
volatile int counter = 0;

void _start(void)
{
  for (;;) {
    counter = counter + 1;
  }
}
CEOF
  arm-none-eabi-gcc -nostdlib -g -O0 -o "$FIX/gdbarm/prog" "$FIX/gdbarm/prog.c"
fi

# LSP fixtures ---------------------------------------------------------------
# Root marker + a small C file driven by tests/e2e/mock-lsp.lua.
mkdir -p "$FIX/lsp"
printf '[]\n' > "$FIX/lsp/compile_commands.json"
cat > "$FIX/lsp/sample.c" <<'CEOF'
int foo(void) {
  int boom = 0;
  return boom;
}
CEOF

