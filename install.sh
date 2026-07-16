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
curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz -C "$TMP"
SRC="$TMP/$(basename "$REPO")-$BRANCH"

echo "==> Building (release), this may take a minute"
( cd "$SRC" && swift build -c release )

echo "==> Installing to $DEST (may ask for your password)"
sudo install -d -m 755 "$DEST"
sudo install -m 755 "$SRC/.build/release/$BIN" "$DEST/$BIN"

echo "==> Done. Launch it with:  $BIN"
