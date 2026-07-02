#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Delta.app"
UPDATES_DIR="$ROOT_DIR/dist/updates"

if [[ "${DELTA_SKIP_BUILD:-0}" == "1" ]]; then
  if [[ ! -d "$APP" ]]; then
    printf "DELTA_SKIP_BUILD=1 was set, but %s does not exist.\n" "$APP" >&2
    exit 1
  fi
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"
else
  "$ROOT_DIR/Scripts/build-app.sh"
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ARCHIVE="$UPDATES_DIR/Delta-$SHORT_VERSION-$BUILD_VERSION.zip"

mkdir -p "$UPDATES_DIR"
find "$UPDATES_DIR" -maxdepth 1 -type f \
  \( -name "Delta-*-$BUILD_VERSION.zip" -o -name "Delta-*-$BUILD_VERSION.md" \) \
  ! -name "Delta-$SHORT_VERSION-$BUILD_VERSION.zip" \
  ! -name "Delta-$SHORT_VERSION-$BUILD_VERSION.md" \
  -delete
rm -f "$ARCHIVE" "${ARCHIVE%.zip}.md"

(cd "$ROOT_DIR/dist" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "Delta.app" "$ARCHIVE")

cat > "${ARCHIVE%.zip}.md" <<EOF
# Delta $SHORT_VERSION Beta

- Encrypted backup destinations
- Scheduled Backups for unattended runs
- Local drives, mounted network drives, and cloud destinations
- Full and selected-path restore
- Saved per-job backup and restore logs
- Power-aware scheduling and retention maintenance
- Sparkle automatic update support
EOF

printf "Packaged %s\n" "$ARCHIVE"
