#!/bin/bash
# One-command installer for hidpi.
#   curl -fsSL https://raw.githubusercontent.com/titovcode/hidpi/main/install.sh | bash
set -euo pipefail

REPO="titovcode/hidpi"
BRANCH="main"
BIN="hidpi"
DEST="/usr/local/bin"

echo "==> Installing $BIN from github.com/$REPO"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "Error: hidpi is macOS-only." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Error: 'swift' not found. Install the Xcode Command Line Tools first:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Downloading source"
# Download to a file (with retries) before extracting, so a dropped
# connection mid-stream doesn't corrupt a pipe and can be retried cleanly.
TARBALL="$TMP/src.tar.gz"
curl -fsSL --retry 5 --retry-delay 2 --retry-connrefused --retry-all-errors \
  "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" -o "$TARBALL"
tar xz -C "$TMP" -f "$TARBALL"
SRC="$TMP/$(basename "$REPO")-$BRANCH"

echo "==> Building (release). The first optimized compile can take ~1 minute."
LOG="$TMP/build.log"
( cd "$SRC" && swift build -c release ) >"$LOG" 2>&1 &
BUILD_PID=$!
# Spinner + elapsed timer so the silent optimization step doesn't look hung.
if [ -t 1 ]; then
  spin='|/-\'
  i=0
  start=$(date +%s)
  while kill -0 "$BUILD_PID" 2>/dev/null; do
    i=$(( (i + 1) % 4 ))
    printf "\r    %s compiling... %ss " "${spin:$i:1}" "$(( $(date +%s) - start ))"
    sleep 0.2
  done
  printf "\r\033[K"
fi
if ! wait "$BUILD_PID"; then
  echo "Error: build failed." >&2
  cat "$LOG" >&2
  exit 1
fi
echo "    Build complete."

echo "==> Installing to $DEST (may ask for your password)"
sudo install -d -m 755 "$DEST"
sudo install -m 755 "$SRC/.build/release/$BIN" "$DEST/$BIN"

echo "==> Done. Installed to $DEST/$BIN"
# Launch immediately. Under `curl | bash` stdin is the pipe, so read keys from
# the controlling terminal to keep the interactive picker usable.
if [ -t 1 ] && [ -e /dev/tty ]; then
  echo "==> Launching hidpi..."
  "$DEST/$BIN" </dev/tty || true
else
  echo "    Launch it with:  $BIN"
fi
