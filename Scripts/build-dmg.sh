#!/usr/bin/env bash
# Package Neat into a DMG with a styled Finder background.
#
# Three macOS 26 (Tahoe) traps this works around, all of them silent failures:
#  1. create-dmg styles the window via AppleScript, which no longer works here —
#     the background file is copied in but nothing references it, so the window
#     comes up blank. dmgbuild writes .DS_Store directly instead.
#  2. dmgbuild <= 1.6.5 (the newest on PyPI) also writes a `pBBk` bookmark
#     record, and Finder on 26.2+ refuses to draw the background when it is
#     present. The fix is in 1.6.7, which is git-only and needs Python >= 3.10,
#     so this provisions a venv rather than using whatever pip has.
#  3. The background must be 72 DPI and exactly the window size. A 2x image
#     renders quarter-size and looks broken.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-Release}"
VERSION="$(grep -E 'MARKETING_VERSION' "$ROOT/project.yml" | head -1 | sed -E 's/.*"([0-9][0-9.]*)".*/\1/')"
VERSION="${VERSION:-0.0.0}"
OUT_DIR="$ROOT/release/$VERSION"
DMG_PATH="$OUT_DIR/Neat-$VERSION.dmg"
BG="$ROOT/Assets/dmg/background.png"
SETTINGS="$ROOT/Scripts/dmgbuild-settings.py"
VENV="$ROOT/.dmgvenv"
VENV_PY="$VENV/bin/python"
VOLNAME="Neat"
DMGBUILD_GIT="git+https://github.com/dmgbuild/dmgbuild.git"  # has the Tahoe pBBk fix

APP_PATH="$(xcodebuild -project "$ROOT/Neat.xcodeproj" -scheme Neat -configuration "$CONFIG" \
  -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR/ {d=$2} / FULL_PRODUCT_NAME/ {n=$2} END {print d"/"n}')"

if [ ! -d "$APP_PATH" ]; then
  echo "Building $CONFIG first…"
  xcodebuild -project "$ROOT/Neat.xcodeproj" -scheme Neat -configuration "$CONFIG" build >/dev/null
fi
[ -d "$APP_PATH" ] || { echo "error: no app at $APP_PATH"; exit 1; }
[ -f "$BG" ] || { echo "error: missing background $BG"; exit 1; }

# Provision the venv if it is absent or still has the pBBk-writing version.
needs_setup=0
if [ ! -x "$VENV_PY" ]; then
  needs_setup=1
elif ! "$VENV_PY" -c "import dmgbuild,os,sys; sys.exit(0 if 'pBBk' not in open(os.path.join(os.path.dirname(dmgbuild.__file__),'core.py')).read() else 1)"; then
  needs_setup=1
fi

if [ "$needs_setup" -eq 1 ]; then
  PY="$(command -v python3.12 || command -v python3.11 || true)"
  [ -n "$PY" ] || { echo "error: python3.12 required — brew install python@3.12"; exit 1; }
  echo "Provisioning DMG venv with the Tahoe-fixed dmgbuild…"
  rm -rf "$VENV"
  "$PY" -m venv "$VENV"
  "$VENV_PY" -m pip install --quiet --upgrade pip
  "$VENV_PY" -m pip install --quiet "$DMGBUILD_GIT"
fi

mkdir -p "$OUT_DIR"
rm -f "$DMG_PATH"

"$VENV_PY" -m dmgbuild \
  -s "$SETTINGS" \
  -D app="$APP_PATH" \
  -D background="$BG" \
  "$VOLNAME" \
  "$DMG_PATH"

echo "DMG ready: $DMG_PATH"
