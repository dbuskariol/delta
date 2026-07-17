#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP="${DELTA_RELEASE_APP:-$ROOT_DIR/dist/Delta.app}"
UPDATES_DIR="${DELTA_UPDATES_DIR:-$ROOT_DIR/dist/updates}"
INFO="$APP/Contents/Info.plist"

delta_assert_release_app "$APP" "$DELTA_EXPECTED_TEAM_ID"
if [[ "${DELTA_ALLOW_UNNOTARIZED_PACKAGE:-0}" != "1" ]]; then
  delta_assert_notarized_app "$APP"
fi
"$ROOT_DIR/Scripts/verify-sparkle-update.sh" "$APP" "$UPDATES_DIR"

VERSION="$(delta_plist_value CFBundleShortVersionString "$INFO")"
BUILD="$(delta_plist_value CFBundleVersion "$INFO")"
TEAM="$(delta_signature_team "$APP")"
BASE_NAME="Delta-$VERSION-$BUILD"
ARCHIVE="$UPDATES_DIR/$BASE_NAME.zip"
DISK_IMAGE="$UPDATES_DIR/$BASE_NAME.dmg"
NOTES="$UPDATES_DIR/$BASE_NAME.md"
APPCAST="$UPDATES_DIR/appcast.xml"
SYMBOLS="$ROOT_DIR/dist/symbols/$BASE_NAME.dSYMs.zip"
CHECKSUMS="$UPDATES_DIR/SHA256SUMS"
MANIFEST="$UPDATES_DIR/release.json"
MANIFEST_PLIST="$UPDATES_DIR/.release-manifest.plist"

for artifact in "$ARCHIVE" "$DISK_IMAGE" "$NOTES" "$APPCAST"; do
  [[ -f "$artifact" ]] || delta_fail "release artifact is missing: $artifact"
done
if [[ "${DELTA_ALLOW_UNNOTARIZED_PACKAGE:-0}" == "1" ]]; then
  delta_assert_signed_disk_image "$DISK_IMAGE" "$DELTA_EXPECTED_TEAM_ID"
else
  delta_assert_notarized_disk_image "$DISK_IMAGE" "$DELTA_EXPECTED_TEAM_ID"
fi

(
  cd "$UPDATES_DIR"
  /usr/bin/shasum -a 256 \
    "$(basename "$ARCHIVE")" \
    "$(basename "$DISK_IMAGE")" \
    "$(basename "$NOTES")" \
    "$(basename "$APPCAST")" >"$CHECKSUMS"
  /usr/bin/shasum -a 256 -c "$CHECKSUMS" >/dev/null
)

/bin/rm -f "$MANIFEST" "$MANIFEST_PLIST"
/usr/bin/plutil -create xml1 "$MANIFEST_PLIST"
trap '/bin/rm -f "$MANIFEST_PLIST"' EXIT
/usr/bin/plutil -insert schemaVersion -integer 3 "$MANIFEST_PLIST"
/usr/bin/plutil -insert product -string Delta "$MANIFEST_PLIST"
/usr/bin/plutil -insert bundleIdentifier -string "$DELTA_EXPECTED_BUNDLE_ID" "$MANIFEST_PLIST"
/usr/bin/plutil -insert version -string "$VERSION" "$MANIFEST_PLIST"
/usr/bin/plutil -insert build -string "$BUILD" "$MANIFEST_PLIST"
/usr/bin/plutil -insert minimumSystemVersion -string "$DELTA_EXPECTED_MINIMUM_SYSTEM" "$MANIFEST_PLIST"
/usr/bin/plutil -insert teamIdentifier -string "$TEAM" "$MANIFEST_PLIST"
/usr/bin/plutil -insert gitCommit -string "$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)" "$MANIFEST_PLIST"
/usr/bin/plutil -insert createdAt -string "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$MANIFEST_PLIST"
/usr/bin/plutil -insert notarized -bool "$([[ "${DELTA_ALLOW_UNNOTARIZED_PACKAGE:-0}" == "1" ]] && printf false || printf true)" "$MANIFEST_PLIST"
TAG="$(/usr/bin/git -C "$ROOT_DIR" describe --tags --exact-match 2>/dev/null || true)"
if [[ -n "$TAG" ]]; then
  /usr/bin/plutil -insert gitTag -string "$TAG" "$MANIFEST_PLIST"
fi

/usr/bin/plutil -insert architectures -array "$MANIFEST_PLIST"
architecture_index=0
for architecture in "${DELTA_EXPECTED_ARCHITECTURES[@]}"; do
  /usr/bin/plutil -insert "architectures.$architecture_index" -string "$architecture" "$MANIFEST_PLIST"
  architecture_index=$((architecture_index + 1))
done

/usr/bin/plutil -insert executable -dictionary "$MANIFEST_PLIST"
/usr/bin/plutil -insert executable.name -string Delta "$MANIFEST_PLIST"
/usr/bin/plutil -insert executable.sha256 -string "$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/Delta" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"

/usr/bin/plutil -insert archive -dictionary "$MANIFEST_PLIST"
/usr/bin/plutil -insert archive.name -string "$(basename "$ARCHIVE")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert archive.bytes -integer "$(/usr/bin/stat -f%z "$ARCHIVE")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert archive.sha256 -string "$(/usr/bin/shasum -a 256 "$ARCHIVE" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"

/usr/bin/plutil -insert diskImage -dictionary "$MANIFEST_PLIST"
/usr/bin/plutil -insert diskImage.name -string "$(basename "$DISK_IMAGE")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert diskImage.bytes -integer "$(/usr/bin/stat -f%z "$DISK_IMAGE")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert diskImage.sha256 -string "$(/usr/bin/shasum -a 256 "$DISK_IMAGE" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"

/usr/bin/plutil -insert appcast -dictionary "$MANIFEST_PLIST"
/usr/bin/plutil -insert appcast.name -string "$(basename "$APPCAST")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert appcast.sha256 -string "$(/usr/bin/shasum -a 256 "$APPCAST" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"

/usr/bin/plutil -insert releaseNotes -dictionary "$MANIFEST_PLIST"
/usr/bin/plutil -insert releaseNotes.name -string "$(basename "$NOTES")" "$MANIFEST_PLIST"
/usr/bin/plutil -insert releaseNotes.sha256 -string "$(/usr/bin/shasum -a 256 "$NOTES" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"

if [[ -f "$SYMBOLS" ]]; then
  /usr/bin/plutil -insert debugSymbols -dictionary "$MANIFEST_PLIST"
  /usr/bin/plutil -insert debugSymbols.privateArchiveSha256 -string "$(/usr/bin/shasum -a 256 "$SYMBOLS" | /usr/bin/awk '{print $1}')" "$MANIFEST_PLIST"
  /usr/bin/plutil -insert debugSymbols.uuids -array "$MANIFEST_PLIST"
  uuid_index=0
  while IFS= read -r uuid; do
    /usr/bin/plutil -insert "debugSymbols.uuids.$uuid_index" -string "$uuid" "$MANIFEST_PLIST"
    uuid_index=$((uuid_index + 1))
  done < <(/usr/bin/dwarfdump --uuid "$APP/Contents/MacOS/Delta" "$APP/Contents/Resources/DeltaAgent" "$APP/Contents/MacOS/DeltaSecretBridge" \
    | /usr/bin/awk '{print $2" "$3}' | /usr/bin/sort -u)
fi

/usr/bin/plutil -convert json -r -o "$MANIFEST" "$MANIFEST_PLIST"
/usr/bin/plutil -convert json -o - "$MANIFEST" >/dev/null
"$ROOT_DIR/Scripts/verify-release-assets.sh" "$UPDATES_DIR"
delta_note "Created checksums and release manifest in $UPDATES_DIR"
