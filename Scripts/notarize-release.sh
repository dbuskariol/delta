#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP="${DELTA_NOTARY_APP:-$ROOT_DIR/dist/Delta.app}"
OUTPUT_DIR="${DELTA_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${DELTA_NOTARY_PREPARE_ONLY:-0}"

delta_assert_release_app "$APP" "$DELTA_EXPECTED_TEAM_ID"

SHORT_VERSION="$(delta_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD_VERSION="$(delta_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
ARCHIVE="$OUTPUT_DIR/Delta-$SHORT_VERSION-$BUILD_VERSION-notarization.zip"
SUBMISSION_JSON="$OUTPUT_DIR/notary-submit-app-$SHORT_VERSION-$BUILD_VERSION.json"
LOG_JSON="$OUTPUT_DIR/notary-log-app-$SHORT_VERSION-$BUILD_VERSION.json"

/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -f "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

if [[ "$PREPARE_ONLY" == "1" ]]; then
  /usr/bin/unzip -tqq "$ARCHIVE" || delta_fail 'the notarization archive is unreadable'
  DELTA_NOTARY_PREPARE_ONLY=1 "$ROOT_DIR/Scripts/create-dmg.sh"
  delta_note "Prepared $ARCHIVE"
  exit 0
fi

delta_note 'Submitting the signed app to Apple notarization'
delta_submit_notarization "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"

/usr/bin/xcrun stapler staple "$APP"
delta_assert_release_app "$APP" "$DELTA_EXPECTED_TEAM_ID"
delta_assert_notarized_app "$APP"

DELTA_SKIP_BUILD=1 "$ROOT_DIR/Scripts/package-update.sh"
"$ROOT_DIR/Scripts/generate-appcast.sh"
"$ROOT_DIR/Scripts/create-dmg.sh"

delta_note "Notarized, stapled, and packaged $APP"
