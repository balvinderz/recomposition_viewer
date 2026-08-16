#!/usr/bin/env bash
set -euo pipefail

plugin_dir="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="$plugin_dir/src/android_compose_inspector/generated"

mkdir -p "$output_dir"
protoc \
  --proto_path="$plugin_dir/proto" \
  --python_out="$output_dir" \
  "$plugin_dir/proto/ui_inspector_minimal.proto" \
  "$plugin_dir/proto/compose_layout_inspection_minimal.proto" \
  "$plugin_dir/proto/view_inspector_minimal.proto"

touch "$output_dir/__init__.py"
