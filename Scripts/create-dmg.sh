#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP="${DELTA_DMG_APP:-$ROOT_DIR/dist/Delta.app}"
UPDATES_DIR="${DELTA_DMG_OUTPUT_DIR:-$ROOT_DIR/dist/updates}"
NOTARY_OUTPUT_DIR="${DELTA_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${DELTA_NOTARY_PREPARE_ONLY:-0}"
SIGNING_IDENTITY="${DELTA_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(delta_find_developer_id_identity)"
fi
[[ -n "$SIGNING_IDENTITY" ]] || delta_fail 'no Developer ID Application signing identity is available'
[[ "$SIGNING_IDENTITY" == "$DELTA_EXPECTED_SIGNING_IDENTITY" ]] \
  || delta_fail "DMG signing identity must be $DELTA_EXPECTED_SIGNING_IDENTITY"
delta_assert_release_app "$APP" "$DELTA_EXPECTED_TEAM_ID"
if [[ "$PREPARE_ONLY" != "1" ]]; then
  delta_assert_notarized_app "$APP"
fi

VERSION="$(delta_plist_value CFBundleShortVersionString "$APP/Contents/Info.plist")"
BUILD="$(delta_plist_value CFBundleVersion "$APP/Contents/Info.plist")"
BASE_NAME="Delta-$VERSION-$BUILD"
DISK_IMAGE="$UPDATES_DIR/$BASE_NAME.dmg"
SUBMISSION_JSON="$NOTARY_OUTPUT_DIR/notary-submit-dmg-$VERSION-$BUILD.json"
LOG_JSON="$NOTARY_OUTPUT_DIR/notary-log-dmg-$VERSION-$BUILD.json"
STAGING_DIR="$(/usr/bin/mktemp -d -t delta-dmg-stage.XXXXXX)"
MOUNT_POINT="$(/usr/bin/mktemp -d -t delta-dmg-mount.XXXXXX)"
IS_MOUNTED=0

cleanup() {
  if [[ "$IS_MOUNTED" == "1" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  /bin/rm -rf "$STAGING_DIR" "$MOUNT_POINT"
}
trap cleanup EXIT INT TERM

/bin/mkdir -p "$UPDATES_DIR" "$NOTARY_OUTPUT_DIR"
/usr/bin/ditto "$APP" "$STAGING_DIR/Delta.app"
/bin/ln -s /Applications "$STAGING_DIR/Applications"
/bin/rm -f "$DISK_IMAGE" "$SUBMISSION_JSON" "$LOG_JSON"

delta_note "Creating compressed disk image $DISK_IMAGE"
/usr/bin/hdiutil create \
  -quiet \
  -ov \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -volname "Delta $VERSION" \
  -srcfolder "$STAGING_DIR" \
  "$DISK_IMAGE"
/usr/bin/codesign --sign "$SIGNING_IDENTITY" --timestamp "$DISK_IMAGE"
delta_assert_signed_disk_image "$DISK_IMAGE" "$DELTA_EXPECTED_TEAM_ID"

if [[ "$PREPARE_ONLY" != "1" ]]; then
  delta_note 'Submitting the signed disk image to Apple notarization'
  delta_submit_notarization "$DISK_IMAGE" "$SUBMISSION_JSON" "$LOG_JSON"
  /usr/bin/xcrun stapler staple "$DISK_IMAGE"
  delta_assert_notarized_disk_image "$DISK_IMAGE" "$DELTA_EXPECTED_TEAM_ID"
fi

/usr/bin/hdiutil attach \
  -quiet \
  -readonly \
  -nobrowse \
  -mountpoint "$MOUNT_POINT" \
  "$DISK_IMAGE"
IS_MOUNTED=1
[[ -d "$MOUNT_POINT/Delta.app" ]] || delta_fail 'the disk image does not contain Delta.app'
[[ -L "$MOUNT_POINT/Applications" ]] || delta_fail 'the disk image does not contain the Applications shortcut'
[[ "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || delta_fail 'the disk image Applications shortcut has an unexpected destination'
delta_assert_release_app "$MOUNT_POINT/Delta.app" "$DELTA_EXPECTED_TEAM_ID"
if [[ "$PREPARE_ONLY" != "1" ]]; then
  delta_assert_notarized_app "$MOUNT_POINT/Delta.app"
fi

SOURCE_HASH="$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/Delta" | /usr/bin/awk '{print $1}')"
MOUNTED_HASH="$(/usr/bin/shasum -a 256 "$MOUNT_POINT/Delta.app/Contents/MacOS/Delta" | /usr/bin/awk '{print $1}')"
[[ "$SOURCE_HASH" == "$MOUNTED_HASH" ]] \
  || delta_fail 'the disk image app executable differs from the verified release app'
/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
IS_MOUNTED=0

if [[ "$PREPARE_ONLY" == "1" ]]; then
  delta_note "Prepared signed disk image $DISK_IMAGE without contacting Apple"
else
  delta_note "Created and verified notarized disk image $DISK_IMAGE"
fi
