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
