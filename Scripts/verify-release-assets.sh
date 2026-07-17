#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

UPDATES_DIR="${1:-$ROOT_DIR/dist/updates}"
MANIFEST="$UPDATES_DIR/release.json"
CHECKSUMS="$UPDATES_DIR/SHA256SUMS"
[[ -f "$MANIFEST" ]] || delta_fail "release manifest is missing: $MANIFEST"
[[ -f "$CHECKSUMS" ]] || delta_fail "release checksums are missing: $CHECKSUMS"
/usr/bin/plutil -convert json -o - "$MANIFEST" >/dev/null || delta_fail 'release.json is invalid JSON'

manifest_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null || true
}

VERSION="$(manifest_value version)"
BUILD="$(manifest_value build)"
BASE_NAME="Delta-$VERSION-$BUILD"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
DISK_IMAGE="$UPDATES_DIR/$BASE_NAME.dmg"
NOTES="$UPDATES_DIR/$BASE_NAME.md"
APPCAST="$UPDATES_DIR/appcast.xml"

for artifact in "$ARCHIVE" "$DISK_IMAGE" "$NOTES" "$APPCAST"; do
  [[ -f "$artifact" ]] || delta_fail "release artifact is missing: $artifact"
done

[[ "$(manifest_value schemaVersion)" == "3" ]] || delta_fail 'unexpected release manifest schema'
[[ "$(manifest_value product)" == "Delta" ]] || delta_fail 'release manifest product is not Delta'
[[ "$(manifest_value bundleIdentifier)" == "$DELTA_EXPECTED_BUNDLE_ID" ]] || delta_fail 'release manifest bundle identifier mismatch'
[[ "$(manifest_value minimumSystemVersion)" == "$DELTA_EXPECTED_MINIMUM_SYSTEM" ]] || delta_fail 'release manifest minimum system mismatch'
[[ "$(manifest_value teamIdentifier)" == "$DELTA_EXPECTED_TEAM_ID" ]] || delta_fail 'release manifest team mismatch'
[[ "$(manifest_value archive.name)" == "$(basename "$ARCHIVE")" ]] || delta_fail 'release manifest ZIP name mismatch'
[[ "$(manifest_value diskImage.name)" == "$(basename "$DISK_IMAGE")" ]] || delta_fail 'release manifest DMG name mismatch'
[[ "$(manifest_value appcast.name)" == "$(basename "$APPCAST")" ]] || delta_fail 'release manifest appcast name mismatch'
[[ "$(manifest_value releaseNotes.name)" == "$(basename "$NOTES")" ]] || delta_fail 'release manifest notes name mismatch'

EXPECTED_COMMIT="${DELTA_EXPECTED_RELEASE_COMMIT:-$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)}"
[[ "$(manifest_value gitCommit)" == "$EXPECTED_COMMIT" ]] || delta_fail 'release manifest commit provenance mismatch'
if [[ "${DELTA_REQUIRE_RELEASE_TAG:-0}" == "1" ]]; then
  [[ "$(manifest_value gitTag)" == "v$VERSION" ]] || delta_fail 'release manifest tag provenance mismatch'
fi

(
  cd "$UPDATES_DIR"
  /usr/bin/shasum -a 256 -c "$(basename "$CHECKSUMS")" >/dev/null
)
[[ "$(manifest_value archive.sha256)" == "$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')" ]] || delta_fail 'release manifest ZIP checksum mismatch'
[[ "$(manifest_value diskImage.sha256)" == "$(/usr/bin/shasum -a 256 "$DISK_IMAGE" | /usr/bin/awk '{print $1}')" ]] || delta_fail 'release manifest DMG checksum mismatch'
[[ "$(manifest_value appcast.sha256)" == "$(/usr/bin/shasum -a 256 "$APPCAST" | /usr/bin/awk '{print $1}')" ]] || delta_fail 'release manifest appcast checksum mismatch'
[[ "$(manifest_value releaseNotes.sha256)" == "$(/usr/bin/shasum -a 256 "$NOTES" | /usr/bin/awk '{print $1}')" ]] || delta_fail 'release manifest notes checksum mismatch'

EXTRACTED_DIR="$(/usr/bin/mktemp -d -t delta-release-assets.XXXXXX)"
MOUNT_POINT="$(/usr/bin/mktemp -d -t delta-release-dmg.XXXXXX)"
IS_MOUNTED=0
cleanup() {
  if [[ "$IS_MOUNTED" == "1" ]]; then
    /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  /bin/rm -rf "$EXTRACTED_DIR" "$MOUNT_POINT"
}
trap cleanup EXIT INT TERM

/usr/bin/unzip -tqq "$ARCHIVE" || delta_fail 'release ZIP is unreadable'
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACTED_DIR"
ZIP_APP="$EXTRACTED_DIR/Delta.app"
delta_assert_release_app "$ZIP_APP" "$DELTA_EXPECTED_TEAM_ID"

if [[ "${DELTA_ALLOW_UNNOTARIZED_PACKAGE:-0}" == "1" ]]; then
  [[ "$(manifest_value notarized)" == "false" ]] || delta_fail 'rehearsal manifest incorrectly claims notarization'
  delta_assert_signed_disk_image "$DISK_IMAGE" "$DELTA_EXPECTED_TEAM_ID"
else
  [[ "$(manifest_value notarized)" == "true" ]] || delta_fail 'final manifest does not claim notarization'
  delta_assert_notarized_app "$ZIP_APP"
  delta_assert_notarized_disk_image "$DISK_IMAGE" "$DELTA_EXPECTED_TEAM_ID"
fi

DELTA_RELEASE_APP="$ZIP_APP" "$ROOT_DIR/Scripts/verify-sparkle-update.sh" "$ZIP_APP" "$UPDATES_DIR"

/usr/bin/hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT_POINT" "$DISK_IMAGE"
IS_MOUNTED=1
DMG_APP="$MOUNT_POINT/Delta.app"
[[ -d "$DMG_APP" ]] || delta_fail 'the DMG does not contain Delta.app'
[[ -L "$MOUNT_POINT/Applications" && "$(/usr/bin/readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || delta_fail 'the DMG does not contain a valid Applications shortcut'
delta_assert_release_app "$DMG_APP" "$DELTA_EXPECTED_TEAM_ID"
if [[ "${DELTA_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  delta_assert_notarized_app "$DMG_APP"
fi

for relative_path in \
  Contents/MacOS/Delta \
  Contents/Resources/DeltaAgent \
  Contents/MacOS/DeltaSecretBridge \
  Contents/MacOS/restic \
  Contents/MacOS/rclone
do
  /usr/bin/cmp -s "$ZIP_APP/$relative_path" "$DMG_APP/$relative_path" \
    || delta_fail "ZIP and DMG executables differ: $relative_path"
done
/usr/bin/cmp -s \
  "$ZIP_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
  "$DMG_APP/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
  || delta_fail 'ZIP and DMG Sparkle executables differ'

EXECUTABLE_SHA="$(/usr/bin/shasum -a 256 "$ZIP_APP/Contents/MacOS/Delta" | /usr/bin/awk '{print $1}')"
[[ "$(manifest_value executable.sha256)" == "$EXECUTABLE_SHA" ]] || delta_fail 'release manifest executable checksum mismatch'

/usr/bin/hdiutil detach "$MOUNT_POINT" -quiet
IS_MOUNTED=0
delta_note "Verified the complete Delta $VERSION ($BUILD) release asset graph"
