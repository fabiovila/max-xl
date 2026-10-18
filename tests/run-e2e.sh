#!/bin/bash
# Max XL end-to-end suite.
#
# Builds isolated fixtures + HOME, launches the app headless (needs a
# display; uses $DISPLAY or starts Xvfb), and fails unless ALL E2E PASS
# lands in the log.
#
# Usage: tests/run-e2e.sh [path/to/max-xl] [--keep]
set -e
cd "$(dirname "$0")/.."

BIN="${1:-./build/src/max-xl}"
KEEP=""
if [ "$2" = "--keep" ] || [ "$1" = "--keep" ]; then KEEP=1; fi
if [ "$1" = "--keep" ]; then BIN="./build/src/max-xl"; fi

if [ ! -x "$BIN" ]; then
  echo "binary not found: $BIN (build first)"; exit 2
fi

TDIR=$(mkdir -p /tmp/opencode && mktemp -d /tmp/opencode/e2e-XXXXXX)
export E2E_FIX="$TDIR/fix" E2E_LOG="$TDIR/e2e.log" E2E_MARKER="$TDIR/fix/maxxl-marker.log"
export HOME="$TDIR/home" LITE_USERDIR="$TDIR/user"

"$(pwd)/tests/e2e/make-fixtures.sh" "$E2E_FIX"
mkdir -p "$TDIR/user"
cp "$(pwd)/tests/e2e/init.lua" "$TDIR/user/init.lua"

HAVE_DISPLAY=""
if [ -n "$DISPLAY" ] && xdpyinfo >/dev/null 2>&1; then
  HAVE_DISPLAY=1
fi
if [ -z "$HAVE_DISPLAY" ]; then
  if command -v Xvfb >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1600x900x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 1
    export DISPLAY=:99
  else
    echo "no display and no Xvfb available"; exit 2
  fi
fi

set +e
timeout -s KILL 150 "$BIN" "$E2E_FIX/lxtest/notes.txt" >"$TDIR/app.log" 2>&1
APP_EXIT=$?
set -e

echo "--- results:"
grep -E "ALL E2E PASS|E2E FAIL" "$E2E_LOG" 2>/dev/null || echo "(no result line)"
echo "--- checks passed: $(grep -c " ok$" "$E2E_LOG" 2>/dev/null || echo 0)"

if [ -n "$XVFB_PID" ]; then kill "$XVFB_PID" 2>/dev/null || true; fi
PASS=0
if grep -q "ALL E2E PASS" "$E2E_LOG" 2>/dev/null; then
  PASS=1
else
  echo "--- tail:"
  tail -15 "$E2E_LOG" 2>/dev/null || echo "(no log)"
fi

if [ -z "$KEEP" ]; then
  rm -rf "$TDIR"
else
  echo "kept: $TDIR"
fi

if [ "$PASS" = "1" ]; then
  echo "E2E GREEN (app exit: $APP_EXIT)"
  exit 0
else
  echo "E2E RED (app exit: $APP_EXIT)"
  exit 1
fi
