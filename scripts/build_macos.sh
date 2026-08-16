#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_DIR/app"
BACKEND_DIR="$REPO_DIR/cli"
MODE="${1:-release}"

if [[ "$MODE" != "debug" && "$MODE" != "release" ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "macOS builds must run on macOS." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
cleanup() {
  find "$TEMP_DIR" -mindepth 1 -delete 2>/dev/null || true
  rmdir "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

uv build --project "$BACKEND_DIR" --wheel --out-dir "$TEMP_DIR"
(cd "$APP_DIR" && flutter build macos "--$MODE")

CONFIGURATION="Release"
if [[ "$MODE" == "debug" ]]; then
  CONFIGURATION="Debug"
fi

APP_PATH="$APP_DIR/build/macos/Build/Products/$CONFIGURATION/Recomposition Viewer.app"
RESOURCE_DIR="$APP_PATH/Contents/Resources/backend"
WHEELS=("$TEMP_DIR"/*.whl)

if [[ ! -d "$APP_PATH" || ${#WHEELS[@]} -ne 1 ]]; then
  echo "Expected one backend wheel and app bundle at: $APP_PATH" >&2
  exit 1
fi

mkdir -p "$RESOURCE_DIR"
find "$RESOURCE_DIR" -maxdepth 1 -type f -name '*.whl' -delete
cp "${WHEELS[0]}" "$RESOURCE_DIR/$(basename "${WHEELS[0]}")"
codesign --force --deep --sign - "$APP_PATH"

echo "Built: $APP_PATH"
