#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_DIR/app"
BACKEND_DIR="$REPO_DIR/cli"
SKIP_RUNTIME=false

if [[ "${1:-}" == "--skip-runtime" ]]; then
  SKIP_RUNTIME=true
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Recomposition Viewer's desktop UI currently requires macOS." >&2
  exit 1
fi

for tool in flutter uv pod; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    exit 1
  fi
done

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "Full Xcode is required (not just the Command Line Tools) to build macOS." >&2
  echo "Install it from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
  exit 1
fi

if [[ "$SKIP_RUNTIME" == false ]]; then
  for tool in adb scrcpy; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing runtime tool: $tool" >&2
      echo "Install it before attaching to an Android device." >&2
      exit 1
    fi
  done
fi

UV_SYNC_ARGS=(sync --project "$BACKEND_DIR" --extra test)
PYTEST_LAUNCHER="$BACKEND_DIR/.venv/bin/pytest"
if [[ -f "$PYTEST_LAUNCHER" ]] &&
  ! head -n 1 "$PYTEST_LAUNCHER" | grep -Fq "$BACKEND_DIR/"; then
  # Virtualenv entry points contain absolute paths. Refresh them if a developer
  # moves an existing checkout after bootstrapping it.
  UV_SYNC_ARGS+=(--reinstall)
fi
uv "${UV_SYNC_ARGS[@]}"
flutter pub get --directory "$APP_DIR"

echo "Setup complete. Run: flutter run -d macos"
