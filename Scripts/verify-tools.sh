#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/Resources/Tools/bin"

verify_binary() {
  local name="$1"
  local binary="$TOOLS_DIR/$name"
  local checksum="$TOOLS_DIR/$name.sha256"

  if [[ ! -x "$binary" || ! -f "$checksum" ]]; then
    printf "%s is missing or has no checksum file\n" "$name" >&2
    return 1
  fi

  (cd "$TOOLS_DIR" && /usr/bin/shasum -a 256 -c "$name.sha256")
  /usr/bin/lipo "$binary" -verify_arch arm64 x86_64 >/dev/null
}

verify_binary restic
verify_binary rclone
