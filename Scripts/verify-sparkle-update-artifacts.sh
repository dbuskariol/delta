#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT_DIR/dist/Delta.app}"
UPDATES_DIR="${2:-$ROOT_DIR/dist/updates}"
APPCAST="$UPDATES_DIR/appcast.xml"

fail() {
  printf "Sparkle update artifact verification failed: %s\n" "$1" >&2
  exit 1
}

plist_value() {
  local key="$1"
  local plist="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

xml_value() {
  local expression="$1"
  /usr/bin/xmllint --xpath "string($expression)" "$APPCAST" 2>/dev/null || true
}

require_file() {
  local path="$1"
  [[ -f "$path" ]] || fail "missing required file $path"
}

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || fail "missing executable $path"
}

[[ -d "$APP" ]] || fail "app bundle not found at $APP"
require_file "$APPCAST"

INFO_PLIST="$APP/Contents/Info.plist"
require_file "$INFO_PLIST"

BUNDLE_ID="$(plist_value CFBundleIdentifier "$INFO_PLIST")"
SHORT_VERSION="$(plist_value CFBundleShortVersionString "$INFO_PLIST")"
BUILD_VERSION="$(plist_value CFBundleVersion "$INFO_PLIST")"
FEED_URL="$(plist_value SUFeedURL "$INFO_PLIST")"
PUBLIC_KEY="$(plist_value SUPublicEDKey "$INFO_PLIST")"
VERIFY_BEFORE_EXTRACTION="$(plist_value SUVerifyUpdateBeforeExtraction "$INFO_PLIST")"
AUTOMATIC_CHECKS="$(plist_value SUEnableAutomaticChecks "$INFO_PLIST")"

[[ "$BUNDLE_ID" == "com.delta.backup" ]] || fail "unexpected bundle identifier '$BUNDLE_ID'"
[[ -n "$SHORT_VERSION" ]] || fail "missing CFBundleShortVersionString"
[[ -n "$BUILD_VERSION" ]] || fail "missing CFBundleVersion"
[[ "$FEED_URL" == "https://github.com/dbuskariol/delta/releases/latest/download/appcast.xml" ]] || fail "unexpected SUFeedURL '$FEED_URL'"
[[ -n "$PUBLIC_KEY" && "$PUBLIC_KEY" != *"TODO"* ]] || fail "missing Sparkle public EdDSA key"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/=]+$ ]] || fail "Sparkle public EdDSA key is not base64"
[[ "$VERIFY_BEFORE_EXTRACTION" == "true" ]] || fail "SUVerifyUpdateBeforeExtraction must be true"
[[ "$AUTOMATIC_CHECKS" == "true" ]] || fail "SUEnableAutomaticChecks must be true"

ARCHIVE_NAME="Delta-$SHORT_VERSION-$BUILD_VERSION.zip"
RELEASE_NOTES_NAME="Delta-$SHORT_VERSION-$BUILD_VERSION.md"
ARCHIVE="$UPDATES_DIR/$ARCHIVE_NAME"
RELEASE_NOTES="$UPDATES_DIR/$RELEASE_NOTES_NAME"
require_file "$ARCHIVE"
require_file "$RELEASE_NOTES"

if ! /usr/bin/grep -Fq "# Delta $SHORT_VERSION Beta" "$RELEASE_NOTES"; then
  fail "release notes $RELEASE_NOTES_NAME do not describe Delta $SHORT_VERSION"
fi
if ! /usr/bin/grep -Fq "Sparkle automatic update support" "$RELEASE_NOTES"; then
  fail "release notes $RELEASE_NOTES_NAME do not include automatic update support"
fi

ITEM_COUNT="$(/usr/bin/xmllint --xpath 'count(/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"])' "$APPCAST" 2>/dev/null || true)"
[[ "$ITEM_COUNT" == "1" ]] || fail "appcast should contain exactly one update item, found '$ITEM_COUNT'"

APPCAST_SHORT_VERSION="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="shortVersionString"]')"
APPCAST_BUILD_VERSION="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="version"]')"
APPCAST_MINIMUM_SYSTEM="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="minimumSystemVersion"]')"
APPCAST_NOTES_URL="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="releaseNotesLink"]')"
APPCAST_ARCHIVE_URL="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"][1]/@url')"
APPCAST_ARCHIVE_LENGTH="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"][1]/@length')"
APPCAST_ARCHIVE_TYPE="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"][1]/@type')"
APPCAST_SIGNATURE="$(xml_value '/*[local-name()="rss"]/*[local-name()="channel"]/*[local-name()="item"][1]/*[local-name()="enclosure"][1]/@*[local-name()="edSignature"]')"

DOWNLOAD_PREFIX="https://github.com/dbuskariol/delta/releases/latest/download/"
EXPECTED_ARCHIVE_URL="$DOWNLOAD_PREFIX$ARCHIVE_NAME"
EXPECTED_NOTES_URL="$DOWNLOAD_PREFIX$RELEASE_NOTES_NAME"
ARCHIVE_LENGTH="$(/usr/bin/stat -f%z "$ARCHIVE")"

[[ "$APPCAST_SHORT_VERSION" == "$SHORT_VERSION" ]] || fail "appcast short version '$APPCAST_SHORT_VERSION' does not match '$SHORT_VERSION'"
[[ "$APPCAST_BUILD_VERSION" == "$BUILD_VERSION" ]] || fail "appcast build version '$APPCAST_BUILD_VERSION' does not match '$BUILD_VERSION'"
[[ "$APPCAST_MINIMUM_SYSTEM" == "26.0" ]] || fail "appcast minimum system version must be 26.0"
[[ "$APPCAST_NOTES_URL" == "$EXPECTED_NOTES_URL" ]] || fail "appcast release notes URL '$APPCAST_NOTES_URL' does not match '$EXPECTED_NOTES_URL'"
[[ "$APPCAST_ARCHIVE_URL" == "$EXPECTED_ARCHIVE_URL" ]] || fail "appcast archive URL '$APPCAST_ARCHIVE_URL' does not match '$EXPECTED_ARCHIVE_URL'"
[[ "$APPCAST_ARCHIVE_LENGTH" == "$ARCHIVE_LENGTH" ]] || fail "appcast archive length '$APPCAST_ARCHIVE_LENGTH' does not match file size '$ARCHIVE_LENGTH'"
[[ "$APPCAST_ARCHIVE_TYPE" == "application/octet-stream" ]] || fail "appcast archive type '$APPCAST_ARCHIVE_TYPE' is unexpected"
[[ "$APPCAST_SIGNATURE" =~ ^[A-Za-z0-9+/=]{40,}$ ]] || fail "appcast enclosure is missing a valid EdDSA signature"

if ! /usr/bin/unzip -tqq "$ARCHIVE"; then
  fail "update archive is not a readable zip"
fi
ARCHIVE_LIST="$(/usr/bin/unzip -Z1 "$ARCHIVE")"
for archived_path in \
  "Delta.app/Contents/Info.plist" \
  "Delta.app/Contents/MacOS/Delta" \
  "Delta.app/Contents/MacOS/DeltaAgent" \
  "Delta.app/Contents/MacOS/DeltaSecretBridge" \
  "Delta.app/Contents/MacOS/restic" \
  "Delta.app/Contents/MacOS/rclone" \
  "Delta.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
  "Delta.app/Contents/Library/LaunchAgents/com.delta.backup.agent.plist"
do
  if ! /usr/bin/grep -Fxq "$archived_path" <<<"$ARCHIVE_LIST"; then
    fail "update archive does not contain $archived_path"
  fi
done

EXTRACT_DIR="$(/usr/bin/mktemp -d -t delta-sparkle-archive.XXXXXX)"
trap '/bin/rm -rf "$EXTRACT_DIR"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/Delta.app"
[[ -d "$EXTRACTED_APP" ]] || fail "update archive did not extract Delta.app"

EXTRACTED_INFO="$EXTRACTED_APP/Contents/Info.plist"
[[ "$(plist_value CFBundleIdentifier "$EXTRACTED_INFO")" == "$BUNDLE_ID" ]] || fail "archived bundle identifier mismatch"
[[ "$(plist_value CFBundleShortVersionString "$EXTRACTED_INFO")" == "$SHORT_VERSION" ]] || fail "archived short version mismatch"
[[ "$(plist_value CFBundleVersion "$EXTRACTED_INFO")" == "$BUILD_VERSION" ]] || fail "archived build version mismatch"
[[ "$(plist_value SUFeedURL "$EXTRACTED_INFO")" == "$FEED_URL" ]] || fail "archived SUFeedURL mismatch"
[[ "$(plist_value SUPublicEDKey "$EXTRACTED_INFO")" == "$PUBLIC_KEY" ]] || fail "archived SUPublicEDKey mismatch"
[[ "$(plist_value SUVerifyUpdateBeforeExtraction "$EXTRACTED_INFO")" == "true" ]] || fail "archived SUVerifyUpdateBeforeExtraction must be true"

require_executable "$EXTRACTED_APP/Contents/MacOS/Delta"
require_executable "$EXTRACTED_APP/Contents/MacOS/DeltaAgent"
require_executable "$EXTRACTED_APP/Contents/MacOS/DeltaSecretBridge"
require_executable "$EXTRACTED_APP/Contents/MacOS/restic"
require_executable "$EXTRACTED_APP/Contents/MacOS/rclone"

if ! /usr/bin/codesign --verify --strict --deep --verbose=2 "$EXTRACTED_APP" >/dev/null 2>&1; then
  fail "extracted update app failed strict code-signature verification"
fi

SOURCE_SIGNING="$(/usr/bin/codesign -dvvv "$APP" 2>&1)"
EXTRACTED_SIGNING="$(/usr/bin/codesign -dvvv "$EXTRACTED_APP" 2>&1)"
SOURCE_IDENTIFIER="$(/usr/bin/awk -F= '/^Identifier=/{print $2; exit}' <<<"$SOURCE_SIGNING")"
EXTRACTED_IDENTIFIER="$(/usr/bin/awk -F= '/^Identifier=/{print $2; exit}' <<<"$EXTRACTED_SIGNING")"
SOURCE_TEAM="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$SOURCE_SIGNING")"
EXTRACTED_TEAM="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$EXTRACTED_SIGNING")"
SOURCE_AUTHORITY="$(/usr/bin/awk -F= '/^Authority=/{print $2; exit}' <<<"$SOURCE_SIGNING")"
EXTRACTED_AUTHORITY="$(/usr/bin/awk -F= '/^Authority=/{print $2; exit}' <<<"$EXTRACTED_SIGNING")"
[[ -n "$SOURCE_IDENTIFIER" && "$SOURCE_IDENTIFIER" == "$EXTRACTED_IDENTIFIER" ]] || fail "archived app signing identifier does not match source app"
[[ -n "$SOURCE_TEAM" && "$SOURCE_TEAM" == "$EXTRACTED_TEAM" ]] || fail "archived app TeamIdentifier does not match source app"
[[ -n "$SOURCE_AUTHORITY" && "$SOURCE_AUTHORITY" == "$EXTRACTED_AUTHORITY" ]] || fail "archived app signing authority does not match source app"

printf "Sparkle update artifacts verified: %s, %s, appcast.xml\n" "$ARCHIVE_NAME" "$RELEASE_NOTES_NAME"
