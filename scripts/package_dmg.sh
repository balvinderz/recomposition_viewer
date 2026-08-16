#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_DIR/app"
MODE="${1:-release}"

if [[ "$MODE" != "debug" && "$MODE" != "release" ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 2
fi

CONFIGURATION="Release"
if [[ "$MODE" == "debug" ]]; then
  CONFIGURATION="Debug"
fi

APP_NAME="Recomposition Viewer.app"
APP_PATH="$APP_DIR/build/macos/Build/Products/$CONFIGURATION/$APP_NAME"
OUT_DIR="$REPO_DIR/dist"
DMG_NAME="Recomposition-Viewer-macOS.dmg"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "DMG packaging must run on macOS." >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found at: $APP_PATH" >&2
  echo "Run ./scripts/build_macos.sh release first." >&2
  exit 1
fi

STAGING_DIR="$(mktemp -d)"
cleanup() {
  find "$STAGING_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$STAGING_DIR" 2>/dev/null || true
}
trap cleanup EXIT

cp -R "$APP_PATH" "$STAGING_DIR/$APP_NAME"
ln -s /Applications "$STAGING_DIR/Applications"

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/$DMG_NAME"

hdiutil create -volname "Recomposition Viewer" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -ov -format UDZO \
  "$OUT_DIR/$DMG_NAME"

echo "Packaged: $OUT_DIR/$DMG_NAME"
