#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$REPO_DIR/app"
BACKEND_DIR="$REPO_DIR/cli"

dart format --output=none --set-exit-if-changed \
  "$APP_DIR/lib" \
  "$APP_DIR/test"

(cd "$APP_DIR" && flutter analyze)
(cd "$APP_DIR" && flutter test)

uv run --project "$BACKEND_DIR" --extra test ruff format --check "$BACKEND_DIR"
uv run --project "$BACKEND_DIR" --extra test ruff check "$BACKEND_DIR"
uv run --project "$BACKEND_DIR" --extra test pytest

echo "All static checks and unit tests passed."
