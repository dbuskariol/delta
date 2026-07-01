#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT_DIR/Resources/AppIcon/DeltaIcon.svg"
ICONSET="$ROOT_DIR/.build/Delta.iconset"
OUTPUT="$ROOT_DIR/Resources/AppIcon/Delta.icns"
MAGICK="${MAGICK:-$(command -v magick)}"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

render_icon() {
  local size="$1"
  local scale="$2"
  local pixels=$((size * scale))
  local suffix=""
  if [[ "$scale" -eq 2 ]]; then
    suffix="@2x"
  fi
  "$MAGICK" -background none "$SOURCE" -resize "${pixels}x${pixels}" "$ICONSET/icon_${size}x${size}${suffix}.png"
}

render_icon 16 1
render_icon 16 2
render_icon 32 1
render_icon 32 2
render_icon 128 1
render_icon 128 2
render_icon 256 1
render_icon 256 2
render_icon 512 1
render_icon 512 2

/usr/bin/iconutil -c icns "$ICONSET" -o "$OUTPUT"
printf "Built %s\n" "$OUTPUT"
