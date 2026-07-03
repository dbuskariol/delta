#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${DELTA_PRODUCTION_APP:-$ROOT_DIR/dist/Delta.app}"
INSTALLED_APP="${DELTA_PRODUCTION_INSTALLED_APP:-/Applications/Delta.app}"
MANUAL_REPORT="${DELTA_MANUAL_ACCEPTANCE_REPORT:-$ROOT_DIR/dist/manual-acceptance/latest.md}"
GATE_STATUS_FILE="$ROOT_DIR/dist/release-evidence/automated-gate-status"
NOTARY_OUTPUT_DIR="${DELTA_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"

fail() {
  printf "Production readiness failed: %s\n" "$1" >&2
  exit 1
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || printf ""
}

gate_status_value() {
  local key="$1"
  /usr/bin/awk -F= -v key="$key" '$1 == key { print $2; exit }' "$GATE_STATUS_FILE" 2>/dev/null || true
}

code_signature_value() {
  local app="$1"
  local key="$2"
  /usr/bin/codesign -dvvv "$app" 2>&1 | /usr/bin/awk -F= -v key="$key" '$1 == key && value == "" { value = $2 } END { print value }'
}

manual_report_value() {
  local key="$1"
  /usr/bin/awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$MANUAL_REPORT" 2>/dev/null || true
}

if [[ ! -d "$APP" ]]; then
  fail "app bundle not found at $APP. Run Scripts/verify-release.sh with a Developer ID signing identity first."
fi

if [[ ! -d "$INSTALLED_APP" ]]; then
  fail "installed app not found at $INSTALLED_APP. Run Scripts/install-app.sh after building the release candidate."
fi

if [[ "${DELTA_PRODUCTION_ALLOW_DIRTY:-0}" != "1" \
  && -n "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]
then
  fail "git worktree is not clean. Commit or remove local changes before external release verification."
fi

HEAD_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)"
if [[ ! -f "$GATE_STATUS_FILE" ]]; then
  fail "automated gate status was not found. Run Scripts/verify-release.sh first."
fi
if [[ "$(gate_status_value status)" != "Passed" ]]; then
  fail "automated gate has not passed for this checkout."
fi
if [[ "$(gate_status_value git_commit)" != "$HEAD_COMMIT" ]]; then
  fail "automated gate was recorded for $(gate_status_value git_commit), not current commit $HEAD_COMMIT."
fi

"$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$MANUAL_REPORT"
if [[ "$(manual_report_value "Git Commit")" != "$HEAD_COMMIT" ]]; then
  fail "manual acceptance report was recorded for $(manual_report_value "Git Commit"), not current commit $HEAD_COMMIT."
fi

APP_INFO_PLIST="$APP/Contents/Info.plist"
INSTALLED_INFO_PLIST="$INSTALLED_APP/Contents/Info.plist"
SHORT_VERSION="$(plist_value "$APP_INFO_PLIST" CFBundleShortVersionString)"
BUILD_VERSION="$(plist_value "$APP_INFO_PLIST" CFBundleVersion)"
BUNDLE_ID="$(plist_value "$APP_INFO_PLIST" CFBundleIdentifier)"

if [[ -z "$SHORT_VERSION" || -z "$BUILD_VERSION" || -z "$BUNDLE_ID" ]]; then
  fail "release app Info.plist is missing bundle id, version, or build."
fi

if [[ "$(plist_value "$INSTALLED_INFO_PLIST" CFBundleIdentifier)" != "$BUNDLE_ID" \
  || "$(plist_value "$INSTALLED_INFO_PLIST" CFBundleShortVersionString)" != "$SHORT_VERSION" \
  || "$(plist_value "$INSTALLED_INFO_PLIST" CFBundleVersion)" != "$BUILD_VERSION" ]]
then
  fail "installed app version does not match $APP."
fi

APP_CDHASH="$(code_signature_value "$APP" CDHash)"
INSTALLED_CDHASH="$(code_signature_value "$INSTALLED_APP" CDHash)"
if [[ -z "$APP_CDHASH" || "$APP_CDHASH" != "$INSTALLED_CDHASH" ]]; then
  fail "installed app code signature hash does not match the verified release app."
fi

/usr/bin/codesign --verify --strict --deep --verbose=2 "$APP"
SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$APP" 2>&1)"
if ! /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS"; then
  fail "external distribution requires a Developer ID Application signature."
fi
if ! /usr/bin/grep -q '^TeamIdentifier=' <<<"$SIGNING_DETAILS"; then
  fail "release app signature does not include a TeamIdentifier."
fi

/usr/bin/xcrun stapler validate "$APP" >/dev/null 2>&1 || fail "release app does not have a valid stapled notarization ticket."
/usr/sbin/spctl --assess --type execute "$APP" >/dev/null 2>&1 || fail "Gatekeeper assessment did not pass for the release app."

SUBMISSION_JSON="$NOTARY_OUTPUT_DIR/notary-submit-$SHORT_VERSION-$BUILD_VERSION.json"
LOG_JSON="$NOTARY_OUTPUT_DIR/notary-log-$SHORT_VERSION-$BUILD_VERSION.json"
if [[ ! -f "$SUBMISSION_JSON" ]]; then
  fail "notarization submission JSON was not archived at $SUBMISSION_JSON."
fi
SUBMISSION_STATUS="$(/usr/bin/plutil -extract status raw -o - "$SUBMISSION_JSON" 2>/dev/null || true)"
if [[ "$SUBMISSION_STATUS" != "Accepted" ]]; then
  fail "archived notarization submission status is ${SUBMISSION_STATUS:-unknown}, not Accepted."
fi
if [[ ! -f "$LOG_JSON" ]]; then
  fail "notarization log JSON was not archived at $LOG_JSON."
fi

DELTA_VERIFY_INSTALLED_LAUNCH="${DELTA_PRODUCTION_VERIFY_INSTALLED_LAUNCH:-1}" \
  "$ROOT_DIR/Scripts/verify-installed-app.sh" "$INSTALLED_APP"

"$ROOT_DIR/Scripts/verify-external-acceptance-evidence.sh" "$INSTALLED_APP"

EVIDENCE_OUTPUT="$(DELTA_EVIDENCE_INSTALLED_APP="$INSTALLED_APP" "$ROOT_DIR/Scripts/collect-release-evidence.sh" "$APP")"
printf "%s\n" "$EVIDENCE_OUTPUT"
EVIDENCE_PATH="$(printf "%s\n" "$EVIDENCE_OUTPUT" | /usr/bin/awk '/^Wrote release evidence to / { print substr($0, 27); exit }')"
if [[ -z "$EVIDENCE_PATH" || ! -f "$EVIDENCE_PATH" ]]; then
  fail "release evidence was not generated."
fi
if ! /usr/bin/grep -q '^- Ready for external distribution: Yes$' "$EVIDENCE_PATH"; then
  fail "release evidence did not mark the build ready for external distribution."
fi

printf "Production readiness verified for Delta %s (%s) at commit %s\n" "$SHORT_VERSION" "$BUILD_VERSION" "$HEAD_COMMIT"
