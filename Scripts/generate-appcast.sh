#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPDATES_DIR="$ROOT_DIR/dist/updates"
GENERATE_APPCAST="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [[ ! -x "$GENERATE_APPCAST" ]]; then
  /usr/bin/swift build --product Delta
fi

if [[ ! -d "$UPDATES_DIR" || -z "$(find "$UPDATES_DIR" -maxdepth 1 -name 'Delta-*.zip' -print -quit)" ]]; then
  "$ROOT_DIR/Scripts/package-update.sh"
fi

"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/dbuskariol/delta/releases/latest/download/" \
  --auto-prune-update-files \
  "$UPDATES_DIR"
printf "Generated %s\n" "$UPDATES_DIR/appcast.xml"
