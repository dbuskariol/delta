#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

DERIVED_DATA="${DELTA_DERIVED_DATA:-$(delta_default_derived_data Release)}"
OUTPUT_DIR="${DELTA_OUTPUT_DIR:-$ROOT_DIR/dist}"
ARCHIVE_PATH="${DELTA_ARCHIVE_PATH:-$OUTPUT_DIR/Delta.xcarchive}"
BUILT_APP="$ARCHIVE_PATH/Products/Applications/Delta.app"
EXPORT_PATH="${DELTA_EXPORT_PATH:-$OUTPUT_DIR/export}"
EXPORTED_APP="$EXPORT_PATH/Delta.app"
EXPORT_OPTIONS_PLIST="$OUTPUT_DIR/DeveloperIDExportOptions.plist"
OUTPUT_APP="$OUTPUT_DIR/Delta.app"
SIGNING_IDENTITY="${DELTA_CODESIGN_IDENTITY:-}"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(delta_find_developer_id_identity)"
fi
[[ -n "$SIGNING_IDENTITY" ]] || delta_fail 'no Developer ID Application signing identity is available'
[[ "$SIGNING_IDENTITY" == "$DELTA_EXPECTED_SIGNING_IDENTITY" ]] \
  || delta_fail "release signing identity must be $DELTA_EXPECTED_SIGNING_IDENTITY"
[[ "$DELTA_EXPECTED_TEAM_ID" == "BJCVJ5G7MJ" ]] \
  || delta_fail "release team must be BJCVJ5G7MJ (found $DELTA_EXPECTED_TEAM_ID)"

"$ROOT_DIR/Scripts/bootstrap-tools.sh"
"$ROOT_DIR/Scripts/verify-tools.sh"
"$ROOT_DIR/Scripts/build-icon.sh"

delta_note "Archiving a universal Developer ID release with $SIGNING_IDENTITY"
/bin/mkdir -p "$OUTPUT_DIR"
/bin/rm -rf "$ARCHIVE_PATH"

XCODE_ARGS=(
  -project "$ROOT_DIR/Delta.xcodeproj"
  -scheme Delta
  -configuration Release
  -destination "generic/platform=macOS"
  -derivedDataPath "$DERIVED_DATA"
  -archivePath "$ARCHIVE_PATH"
  CLANG_ENABLE_CODE_COVERAGE=NO
  GCC_GENERATE_TEST_COVERAGE_FILES=NO
  GCC_INSTRUMENT_PROGRAM_FLOW_ARCS=NO
  ARCHS="arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
  CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
  DEVELOPMENT_TEAM="$DELTA_EXPECTED_TEAM_ID"
)
if [[ "${DELTA_VERBOSE_BUILD:-0}" != "1" ]]; then
  XCODE_ARGS=(-quiet "${XCODE_ARGS[@]}")
fi

/usr/bin/xcodebuild "${XCODE_ARGS[@]}" clean archive

[[ -d "$BUILT_APP" ]] || delta_fail "release app was not archived at $BUILT_APP"

ARCHIVED_TEAM="$(delta_signature_team "$BUILT_APP")"
[[ -n "$ARCHIVED_TEAM" && "$ARCHIVED_TEAM" != "not set" ]] \
  || delta_fail 'the archived app signature is missing its team identifier'
[[ "$ARCHIVED_TEAM" == "$DELTA_EXPECTED_TEAM_ID" ]] \
  || delta_fail "archive team $ARCHIVED_TEAM does not match expected team $DELTA_EXPECTED_TEAM_ID"

# Exporting is a required distribution step, not a redundant copy. Xcode
# re-signs every nested Sparkle helper in the correct inside-out order with the
# selected Developer ID identity and secure timestamp.
/bin/rm -rf "$EXPORT_PATH"
/bin/rm -f "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -create xml1 "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert method -string developer-id "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert signingStyle -string manual "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert teamID -string "$ARCHIVED_TEAM" "$EXPORT_OPTIONS_PLIST"
/usr/bin/plutil -insert signingCertificate -string "$SIGNING_IDENTITY" "$EXPORT_OPTIONS_PLIST"

EXPORT_ARGS=(
  -exportArchive
  -archivePath "$ARCHIVE_PATH"
  -exportPath "$EXPORT_PATH"
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"
)
if [[ "${DELTA_VERBOSE_BUILD:-0}" != "1" ]]; then
  EXPORT_ARGS=(-quiet "${EXPORT_ARGS[@]}")
fi
/usr/bin/xcodebuild "${EXPORT_ARGS[@]}"

[[ -d "$EXPORTED_APP" ]] || delta_fail "Developer ID export did not produce $EXPORTED_APP"
/bin/rm -rf "$OUTPUT_APP"
/usr/bin/ditto "$EXPORTED_APP" "$OUTPUT_APP"
delta_assert_release_app "$OUTPUT_APP" "$DELTA_EXPECTED_TEAM_ID"

VERSION="$(delta_plist_value CFBundleShortVersionString "$OUTPUT_APP/Contents/Info.plist")"
BUILD="$(delta_plist_value CFBundleVersion "$OUTPUT_APP/Contents/Info.plist")"
SYMBOLS_DIR="$OUTPUT_DIR/symbols"
SYMBOLS_ARCHIVE="$SYMBOLS_DIR/Delta-$VERSION-$BUILD.dSYMs.zip"
DSYMS_DIR="$ARCHIVE_PATH/dSYMs"
[[ -d "$DSYMS_DIR/Delta.app.dSYM" ]] \
  || delta_fail 'the release archive did not contain Delta.app.dSYM'

for product in Delta DeltaAgent DeltaSecretBridge; do
  case "$product" in
    Delta) binary="$OUTPUT_APP/Contents/MacOS/Delta"; dsym="$DSYMS_DIR/Delta.app.dSYM/Contents/Resources/DWARF/Delta" ;;
    *) binary="$OUTPUT_APP/Contents/MacOS/$product"; dsym="$DSYMS_DIR/$product.dSYM/Contents/Resources/DWARF/$product" ;;
  esac
  [[ -f "$dsym" ]] || delta_fail "the release archive did not contain matching symbols for $product"
  binary_uuids="$(/usr/bin/dwarfdump --uuid "$binary" | /usr/bin/awk '{print $2" "$3}' | /usr/bin/sort)"
  dsym_uuids="$(/usr/bin/dwarfdump --uuid "$dsym" | /usr/bin/awk '{print $2" "$3}' | /usr/bin/sort)"
  [[ -n "$binary_uuids" && "$binary_uuids" == "$dsym_uuids" ]] \
    || delta_fail "dSYM UUIDs do not match $product"
done

/bin/mkdir -p "$SYMBOLS_DIR"
/bin/rm -f "$SYMBOLS_ARCHIVE"
/usr/bin/ditto -c -k --keepParent "$DSYMS_DIR" "$SYMBOLS_ARCHIVE"
/usr/bin/unzip -tqq "$SYMBOLS_ARCHIVE" || delta_fail 'the dSYM archive is unreadable'

delta_note "Built and verified $OUTPUT_APP"
delta_note "Archived debug symbols at $SYMBOLS_ARCHIVE"
