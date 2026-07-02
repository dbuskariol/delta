#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_EVIDENCE_APP:-$ROOT_DIR/dist/Delta.app}}"
OUTPUT_DIR="${DELTA_EVIDENCE_DIR:-$ROOT_DIR/dist/release-evidence}"

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-release-evidence-$TIMESTAMP.md"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
GATE_STATUS_FILE="$ROOT_DIR/dist/release-evidence/automated-gate-status"
MANUAL_ACCEPTANCE_REPORT="${DELTA_MANUAL_ACCEPTANCE_REPORT:-$ROOT_DIR/dist/manual-acceptance/latest.md}"

plist_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || printf "Unknown"
}

append_command() {
  local title="$1"
  shift
  {
    printf "### %s\n\n" "$title"
    printf '```text\n'
    "$@" 2>&1 || printf "Command exited with status %s\n" "$?"
    printf '```\n\n'
  } >>"$OUTPUT"
}

SHORT_VERSION="$(plist_value CFBundleShortVersionString)"
BUILD_VERSION="$(plist_value CFBundleVersion)"
BUNDLE_ID="$(plist_value CFBundleIdentifier)"
GIT_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")"

gate_status_value() {
  local key="$1"
  /usr/bin/awk -F= -v key="$key" '$1 == key { print $2; exit }' "$GATE_STATUS_FILE" 2>/dev/null || true
}

AUTOMATED_GATE_STATUS="${DELTA_AUTOMATED_GATE_STATUS:-}"
if [[ -z "$AUTOMATED_GATE_STATUS" && -f "$GATE_STATUS_FILE" ]]; then
  if [[ "$(gate_status_value git_commit)" == "$GIT_COMMIT" ]]; then
    AUTOMATED_GATE_STATUS="$(gate_status_value status)"
  else
    AUTOMATED_GATE_STATUS="Not recorded for $GIT_COMMIT"
  fi
fi
if [[ -z "$AUTOMATED_GATE_STATUS" ]]; then
  AUTOMATED_GATE_STATUS="Not recorded in this report"
fi

NOTARIZATION_COMPLETE="No"
SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1 || true)"
if /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS" \
  && /usr/bin/stapler validate "$APP_PATH" >/dev/null 2>&1 \
  && /usr/sbin/spctl --assess --type execute "$APP_PATH" >/dev/null 2>&1
then
  NOTARIZATION_COMPLETE="Yes"
fi

cat >"$OUTPUT" <<EOF
# Delta Release Evidence

- Generated: $TIMESTAMP UTC
- App: $APP_PATH
- Bundle ID: $BUNDLE_ID
- Version: $SHORT_VERSION
- Build: $BUILD_VERSION
- Git Commit: $GIT_COMMIT
- Host macOS: $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))

## Automated Evidence

EOF

append_command "Code Signature Verification" /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_PATH"
append_command "Code Signature Details" /usr/bin/codesign -dvv "$APP_PATH"
append_command "Gatekeeper Assessment" /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
append_command "Stapled Notarization Ticket" /usr/bin/stapler validate "$APP_PATH"
append_command "Background Backups Helper Status" "$APP_PATH/Contents/MacOS/DeltaAgent" --status
append_command "Background Backups Helper Dry Run" "$APP_PATH/Contents/MacOS/DeltaAgent" --dry-run
ISOLATED_AGENT_SUPPORT="$(/usr/bin/mktemp -d -t delta-agent-support.XXXXXX)"
append_command "Background Backups Isolated Due-Run" /bin/sh -c "DELTA_APP_SUPPORT_DIR='$ISOLATED_AGENT_SUPPORT' '$APP_PATH/Contents/MacOS/DeltaAgent' && test -f '$ISOLATED_AGENT_SUPPORT/Delta.sqlite'"
/bin/rm -rf "$ISOLATED_AGENT_SUPPORT"
if [[ -d "/Applications/Delta.app" ]]; then
  append_command "Installed App Smoke Verification" "$ROOT_DIR/Scripts/verify-installed-app.sh" "/Applications/Delta.app"
fi
append_command "Bundled Backup Engine" "$APP_PATH/Contents/MacOS/restic" version
append_command "Bundled Cloud Helper" "$APP_PATH/Contents/MacOS/rclone" version
append_command "Secret Bridge Fail-Closed Check" /bin/sh -c "'$APP_PATH/Contents/MacOS/DeltaSecretBridge' 2>&1; test \$? -eq 64"

if [[ -d "$ROOT_DIR/dist/updates" ]]; then
  append_command "Sparkle Update Artifacts" /bin/sh -c "ls -la '$ROOT_DIR/dist/updates' && test -f '$ROOT_DIR/dist/updates/appcast.xml' && grep -E 'sparkle:(version|shortVersionString)|sparkle:edSignature' '$ROOT_DIR/dist/updates/appcast.xml'"
fi

if [[ -f "$GATE_STATUS_FILE" ]]; then
  append_command "Automated Gate Status File" /bin/cat "$GATE_STATUS_FILE"
fi

if [[ -x "$ROOT_DIR/Scripts/run-local-acceptance-probe.sh" ]]; then
  append_command "Local Acceptance Probe" "$ROOT_DIR/Scripts/run-local-acceptance-probe.sh" "$APP_PATH"
  if [[ -f "$ROOT_DIR/dist/local-acceptance/latest.md" ]]; then
    append_command "Local Acceptance Probe Report" /bin/cat "$ROOT_DIR/dist/local-acceptance/latest.md"
  fi
  if [[ -f "$ROOT_DIR/dist/local-acceptance/installed-local-backup-latest.md" ]]; then
    append_command "Installed Local Backup Acceptance Report" /bin/cat "$ROOT_DIR/dist/local-acceptance/installed-local-backup-latest.md"
  fi
  if [[ -f "$ROOT_DIR/dist/local-acceptance/installed-keychain-access-latest.md" ]]; then
    append_command "Installed Keychain Access Acceptance Report" /bin/cat "$ROOT_DIR/dist/local-acceptance/installed-keychain-access-latest.md"
  fi
  for external_report in "$ROOT_DIR"/dist/local-acceptance/external-*-acceptance-latest.md; do
    if [[ -f "$external_report" ]]; then
      append_command "External Backend Acceptance Report: $(/usr/bin/basename "$external_report")" /bin/cat "$external_report"
    fi
  done
fi

MANUAL_MATRIX_PASSED="No"
if [[ -f "$MANUAL_ACCEPTANCE_REPORT" ]]; then
  MANUAL_ACCEPTANCE_OUTPUT="$(/usr/bin/mktemp -t delta-manual-acceptance.XXXXXX)"
  set +e
  "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$MANUAL_ACCEPTANCE_REPORT" >"$MANUAL_ACCEPTANCE_OUTPUT" 2>&1
  MANUAL_ACCEPTANCE_STATUS=$?
  set -e
  if [[ "$MANUAL_ACCEPTANCE_STATUS" -eq 0 ]]; then
    MANUAL_MATRIX_PASSED="Yes"
  fi
  {
    printf "### Manual Acceptance Verification\n\n"
    printf '```text\n'
    /bin/cat "$MANUAL_ACCEPTANCE_OUTPUT"
    printf '```\n\n'
  } >>"$OUTPUT"
  /bin/rm -f "$MANUAL_ACCEPTANCE_OUTPUT"
  append_command "Manual Acceptance Report" /bin/cat "$MANUAL_ACCEPTANCE_REPORT"
else
  cat >>"$OUTPUT" <<EOF
### Manual Acceptance Verification

\`\`\`text
Manual acceptance report was not found at $MANUAL_ACCEPTANCE_REPORT.
Create one with Scripts/create-manual-acceptance-report.sh, fill it in, then rerun this evidence collector.
\`\`\`

EOF
fi

READY_FOR_EXTERNAL_DISTRIBUTION="No"
if [[ "$AUTOMATED_GATE_STATUS" == "Passed" && "$MANUAL_MATRIX_PASSED" == "Yes" && "$NOTARIZATION_COMPLETE" == "Yes" ]]; then
  READY_FOR_EXTERNAL_DISTRIBUTION="Yes"
fi

cat >>"$OUTPUT" <<EOF
## Manual macOS Acceptance Evidence

Manual acceptance report: $MANUAL_ACCEPTANCE_REPORT
Manual matrix passed: $MANUAL_MATRIX_PASSED

## Release Decision

- Automated gate passed: $AUTOMATED_GATE_STATUS
- Manual matrix passed: $MANUAL_MATRIX_PASSED
- Developer ID notarization complete: $NOTARIZATION_COMPLETE
- Ready for external distribution: $READY_FOR_EXTERNAL_DISTRIBUTION
EOF

printf "Wrote release evidence to %s\n" "$OUTPUT"
