#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP="$ROOT_DIR/dist/Delta.app"
UPDATES_DIR="$ROOT_DIR/dist/updates"
NOTES_SOURCE="${DELTA_RELEASE_NOTES_FILE:-$ROOT_DIR/Documentation/RELEASE_NOTES.md}"

if [[ "${DELTA_SKIP_BUILD:-0}" != "1" ]]; then
  "$ROOT_DIR/Scripts/build-release.sh"
fi

[[ -d "$APP" ]] || delta_fail "app bundle not found: $APP"
[[ -f "$NOTES_SOURCE" ]] || delta_fail "release notes not found: $NOTES_SOURCE"
delta_assert_release_app "$APP" "$DELTA_EXPECTED_TEAM_ID"
if [[ "${DELTA_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  delta_assert_notarized_app "$APP"
fi

SHORT_VERSION="$(delta_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD_VERSION="$(delta_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
BASE_NAME="Delta-$SHORT_VERSION-$BUILD_VERSION"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
NOTES="$UPDATES_DIR/$BASE_NAME.md"

[[ "$(/usr/bin/sed -n '1p' "$NOTES_SOURCE")" == "# Delta $SHORT_VERSION" ]] \
  || delta_fail "release notes do not match Delta $SHORT_VERSION"

/bin/mkdir -p "$UPDATES_DIR"
/bin/rm -f "$ARCHIVE" "$NOTES"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/bin/cp "$NOTES_SOURCE" "$NOTES"
/usr/bin/unzip -tqq "$ARCHIVE" || delta_fail 'the generated update archive is unreadable'

delta_note "Packaged $ARCHIVE"
