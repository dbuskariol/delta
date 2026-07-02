#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_APP="$ROOT_DIR/dist/Delta.app"
APP="${DELTA_NOTARY_APP:-$DEFAULT_APP}"
OUTPUT_DIR="${DELTA_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"
PREPARE_ONLY="${DELTA_NOTARY_PREPARE_ONLY:-0}"
REPACKAGE_SPARKLE="${DELTA_NOTARY_REPACKAGE_SPARKLE:-1}"

if [[ ! -d "$APP" ]]; then
  printf "App bundle not found: %s\nRun DELTA_CODESIGN_IDENTITY=\"Developer ID Application: ...\" Scripts/build-app.sh first.\n" "$APP" >&2
  exit 1
fi

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"

SIGNING_DETAILS="$(/usr/bin/codesign -dv "$APP" 2>&1)"
if ! /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS"; then
  printf "Notarization requires a Developer ID Application signature.\n" >&2
  printf "Current signing details:\n%s\n" "$SIGNING_DETAILS" >&2
  exit 1
fi
if ! /usr/bin/grep -q '^TeamIdentifier=' <<<"$SIGNING_DETAILS"; then
  printf "The app signature does not include a TeamIdentifier.\n" >&2
  exit 1
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
ARCHIVE="$OUTPUT_DIR/Delta-$SHORT_VERSION-$BUILD_VERSION-notarization.zip"
SUBMISSION_JSON="$OUTPUT_DIR/notary-submit-$SHORT_VERSION-$BUILD_VERSION.json"
LOG_JSON="$OUTPUT_DIR/notary-log-$SHORT_VERSION-$BUILD_VERSION.json"

mkdir -p "$OUTPUT_DIR"
rm -f "$ARCHIVE" "$SUBMISSION_JSON" "$LOG_JSON"

(cd "$(dirname "$APP")" && /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$(basename "$APP")" "$ARCHIVE")
printf "Prepared notarization archive %s\n" "$ARCHIVE"

if [[ "$PREPARE_ONLY" == "1" ]]; then
  printf "DELTA_NOTARY_PREPARE_ONLY=1 set; skipping Apple submission.\n"
  exit 0
fi

NOTARY_ARGS=()
if [[ -n "${DELTA_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$DELTA_NOTARY_KEYCHAIN_PROFILE")
elif [[ -n "${DELTA_NOTARY_APPLE_ID:-}" && -n "${DELTA_NOTARY_TEAM_ID:-}" && -n "${DELTA_NOTARY_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(
    --apple-id "$DELTA_NOTARY_APPLE_ID"
    --team-id "$DELTA_NOTARY_TEAM_ID"
    --password "$DELTA_NOTARY_PASSWORD"
  )
else
  cat >&2 <<'EOF'
Notarization credentials are not configured.

Preferred:
  xcrun notarytool store-credentials "Delta Notary" --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
  DELTA_NOTARY_KEYCHAIN_PROFILE="Delta Notary" Scripts/notarize-release.sh

Alternative environment variables:
  DELTA_NOTARY_APPLE_ID
  DELTA_NOTARY_TEAM_ID
  DELTA_NOTARY_PASSWORD
EOF
  exit 1
fi

/usr/bin/xcrun notarytool submit "$ARCHIVE" "${NOTARY_ARGS[@]}" --wait --output-format json > "$SUBMISSION_JSON"

SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"
SUBMISSION_STATUS="$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"

if [[ -n "$SUBMISSION_ID" ]]; then
  /usr/bin/xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" --output-format json > "$LOG_JSON" || true
fi

if [[ "$SUBMISSION_STATUS" != "Accepted" ]]; then
  printf "Notarization was not accepted. status=%s submission=%s\n" "${SUBMISSION_STATUS:-unknown}" "${SUBMISSION_ID:-unknown}" >&2
  [[ -f "$SUBMISSION_JSON" ]] && printf "Submission details: %s\n" "$SUBMISSION_JSON" >&2
  [[ -f "$LOG_JSON" ]] && printf "Notary log: %s\n" "$LOG_JSON" >&2
  exit 1
fi

/usr/bin/xcrun stapler staple "$APP"
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP"

if [[ "$REPACKAGE_SPARKLE" == "1" ]]; then
  if [[ "$APP" != "$DEFAULT_APP" ]]; then
    printf "DELTA_NOTARY_REPACKAGE_SPARKLE=1 requires the default app path: %s\n" "$DEFAULT_APP" >&2
    printf "Set DELTA_NOTARY_REPACKAGE_SPARKLE=0 when notarizing a custom app path.\n" >&2
    exit 1
  fi
  DELTA_SKIP_BUILD=1 "$ROOT_DIR/Scripts/package-update.sh"
  "$ROOT_DIR/Scripts/generate-appcast.sh"
fi

printf "Notarized and stapled %s\n" "$APP"
[[ -f "$LOG_JSON" ]] && printf "Archived notarization log %s\n" "$LOG_JSON"
