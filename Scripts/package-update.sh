#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/Delta.app"
UPDATES_DIR="$ROOT_DIR/dist/updates"

"$ROOT_DIR/Scripts/build-app.sh"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ARCHIVE="$UPDATES_DIR/Delta-$SHORT_VERSION-$BUILD_VERSION.zip"

mkdir -p "$UPDATES_DIR"
rm -f "$ARCHIVE"

(cd "$ROOT_DIR/dist" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "Delta.app" "$ARCHIVE")

cat > "${ARCHIVE%.zip}.md" <<EOF
# Delta $SHORT_VERSION

- Encrypted backup destinations
- Scheduled LaunchAgent backups
- Local drives, mounted network drives, and cloud destinations
- Full and selected-path restore
EOF

printf "Packaged %s\n" "$ARCHIVE"
