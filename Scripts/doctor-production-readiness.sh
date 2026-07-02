#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${DELTA_DOCTOR_APP:-$ROOT_DIR/dist/Delta.app}"
INSTALLED_APP_PATH="${DELTA_DOCTOR_INSTALLED_APP:-/Applications/Delta.app}"
LOCAL_ACCEPTANCE_REPORT="${DELTA_DOCTOR_LOCAL_ACCEPTANCE_REPORT:-$ROOT_DIR/dist/local-acceptance/latest.md}"
MANUAL_REPORT="${DELTA_DOCTOR_MANUAL_ACCEPTANCE_REPORT:-$ROOT_DIR/dist/manual-acceptance/latest.md}"
GATE_STATUS_FILE="$ROOT_DIR/dist/release-evidence/automated-gate-status"
NOTARY_OUTPUT_DIR="${DELTA_NOTARY_OUTPUT_DIR:-$ROOT_DIR/dist/notarization}"

blockers=0
warnings=0

print_status() {
  local status="$1"
  local message="$2"
  printf -- "- [%s] %s\n" "$status" "$message"
}

pass() {
  print_status "OK" "$1"
}

warn() {
  warnings=$((warnings + 1))
  print_status "WARN" "$1"
}

block() {
  blockers=$((blockers + 1))
  print_status "BLOCKED" "$1"
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

signature_value() {
  local app="$1"
  local key="$2"
  /usr/bin/codesign -dvvv "$app" 2>&1 | /usr/bin/awk -F= -v key="$key" '$1 == key && value == "" { value = $2 } END { print value }'
}

manual_report_value() {
  local key="$1"
  /usr/bin/awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$MANUAL_REPORT" 2>/dev/null || true
}

local_report_value() {
  local key="$1"
  /usr/bin/awk -F': ' -v key="- $key" '$1 == key { print $2; exit }' "$LOCAL_ACCEPTANCE_REPORT" 2>/dev/null || true
}

first_row_for_id() {
  local id="$1"
  /usr/bin/awk -F'|' -v id="$id" '$2 ~ " " id " " { gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4; exit }' "$LOCAL_ACCEPTANCE_REPORT" 2>/dev/null || true
}

printf "# Delta Production Readiness Doctor\n\n"

head_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)"
printf -- "- Repository: %s\n" "$ROOT_DIR"
printf -- "- Commit: %s\n" "$head_commit"
printf -- "- App: %s\n" "$APP_PATH"
printf -- "- Installed app: %s\n\n" "$INSTALLED_APP_PATH"

printf "## Source State\n\n"
if [[ -n "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain --untracked-files=all)" ]]; then
  warn "Git worktree has local changes. External production verification requires a clean tree."
else
  pass "Git worktree is clean."
fi

printf "\n## Signing Prerequisites\n\n"
identity_output="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null || true)"
developer_identities="$(printf "%s\n" "$identity_output" | /usr/bin/awk -F\" '/Developer ID Application/ { print $2 }')"
apple_development_identities="$(printf "%s\n" "$identity_output" | /usr/bin/awk -F\" '/Apple Development/ { print $2 }')"
if [[ -n "$developer_identities" ]]; then
  pass "Developer ID Application identity is installed: $(printf "%s" "$developer_identities" | /usr/bin/head -n 1)"
else
  block "No Developer ID Application signing identity is installed. Notarized external distribution cannot be produced on this machine yet."
fi
if [[ -n "$apple_development_identities" ]]; then
  pass "Apple Development identity is available for local builds: $(printf "%s" "$apple_development_identities" | /usr/bin/head -n 1)"
else
  warn "No Apple Development identity is installed. Local builds may fall back to ad-hoc signing if Developer ID is also absent."
fi

printf "\n## Automated Gate\n\n"
if [[ -f "$GATE_STATUS_FILE" ]]; then
  gate_status="$(gate_status_value status)"
  gate_commit="$(gate_status_value git_commit)"
  if [[ "$gate_status" == "Passed" && "$gate_commit" == "$head_commit" ]]; then
    pass "Automated release gate passed for current commit $head_commit."
  elif [[ "$gate_status" == "Passed" ]]; then
    block "Automated release gate passed for $gate_commit, not current commit $head_commit. Rerun Scripts/verify-release.sh."
  else
    block "Automated release gate has not passed for this checkout."
  fi
else
  block "Automated gate status is missing. Run Scripts/verify-release.sh."
fi

printf "\n## App Bundle\n\n"
if [[ -d "$APP_PATH" ]]; then
  app_info="$APP_PATH/Contents/Info.plist"
  short_version="$(plist_value "$app_info" CFBundleShortVersionString)"
  build_version="$(plist_value "$app_info" CFBundleVersion)"
  bundle_id="$(plist_value "$app_info" CFBundleIdentifier)"
  pass "Release app bundle exists: $bundle_id $short_version ($build_version)."
  if /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_PATH" >/dev/null 2>&1; then
    authority="$(signature_value "$APP_PATH" Authority)"
    team_id="$(signature_value "$APP_PATH" TeamIdentifier)"
    pass "Release app code signature verifies. Authority: ${authority:-Unknown}; Team ID: ${team_id:-Unknown}."
    if [[ "$authority" == Developer\ ID\ Application:* ]]; then
      pass "Release app is signed for Developer ID distribution."
    else
      block "Release app is not signed with Developer ID Application. Current authority: ${authority:-Unknown}."
    fi
  else
    block "Release app code signature does not verify."
  fi
else
  block "Release app bundle is missing. Run Scripts/verify-release.sh."
  short_version=""
  build_version=""
fi

if [[ -d "$INSTALLED_APP_PATH" && -d "$APP_PATH" ]]; then
  app_cdhash="$(signature_value "$APP_PATH" CDHash)"
  installed_cdhash="$(signature_value "$INSTALLED_APP_PATH" CDHash)"
  if [[ -n "$app_cdhash" && "$app_cdhash" == "$installed_cdhash" ]]; then
    pass "Installed app matches the verified app CDHash."
  else
    block "Installed app does not match the verified app CDHash. Run Scripts/install-app.sh dist/Delta.app."
  fi
elif [[ ! -d "$INSTALLED_APP_PATH" ]]; then
  block "Installed app is missing at $INSTALLED_APP_PATH."
fi

printf "\n## Notarization\n\n"
if [[ -d "$APP_PATH" ]] && /usr/bin/xcrun stapler validate "$APP_PATH" >/dev/null 2>&1; then
  pass "Stapled notarization ticket validates."
else
  block "Stapled notarization ticket is missing or invalid."
fi
if [[ -d "$APP_PATH" ]] && /usr/sbin/spctl --assess --type execute "$APP_PATH" >/dev/null 2>&1; then
  pass "Gatekeeper assessment passes."
else
  block "Gatekeeper assessment does not pass for the release app."
fi
if [[ -n "$short_version" && -n "$build_version" ]]; then
  submit_json="$NOTARY_OUTPUT_DIR/notary-submit-$short_version-$build_version.json"
  log_json="$NOTARY_OUTPUT_DIR/notary-log-$short_version-$build_version.json"
  if [[ -f "$submit_json" && "$(/usr/bin/plutil -extract status raw -o - "$submit_json" 2>/dev/null || true)" == "Accepted" ]]; then
    pass "Archived notarization submission JSON is accepted."
  else
    block "Accepted notarization submission JSON is missing at $submit_json."
  fi
  if [[ -f "$log_json" ]]; then
    pass "Archived notarization log exists."
  else
    block "Notarization log JSON is missing at $log_json."
  fi
fi
if [[ -n "${DELTA_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
  pass "DELTA_NOTARY_KEYCHAIN_PROFILE is set."
else
  warn "DELTA_NOTARY_KEYCHAIN_PROFILE is not set. Notarization will need a stored notarytool keychain profile."
fi

printf "\n## Acceptance Evidence\n\n"
if [[ -f "$LOCAL_ACCEPTANCE_REPORT" ]]; then
  local_commit="$(local_report_value "Git Commit")"
  if [[ "$local_commit" == "$head_commit" ]]; then
    pass "Local acceptance report is for current commit $head_commit."
  else
    block "Local acceptance report is for ${local_commit:-unknown}, not current commit $head_commit."
  fi
  printf -- "- Local acceptance summary: Automated pass=%s, Partial=%s, Manual required=%s, Failed=%s\n" \
    "$(/usr/bin/awk -F': ' '$1 == "- Automated pass" { print $2; exit }' "$LOCAL_ACCEPTANCE_REPORT")" \
    "$(/usr/bin/awk -F': ' '$1 == "- Partial automated evidence" { print $2; exit }' "$LOCAL_ACCEPTANCE_REPORT")" \
    "$(/usr/bin/awk -F': ' '$1 == "- Manual required" { print $2; exit }' "$LOCAL_ACCEPTANCE_REPORT")" \
    "$(/usr/bin/awk -F': ' '$1 == "- Failed" { print $2; exit }' "$LOCAL_ACCEPTANCE_REPORT")"
  full_disk_status="$(first_row_for_id full_disk_access)"
  developer_id_status="$(first_row_for_id developer_id_notarization)"
  printf -- "- Full Disk Access local status: ${full_disk_status:-Unknown}\n"
  printf -- "- Developer ID local status: ${developer_id_status:-Unknown}\n"
else
  block "Local acceptance report is missing. Run Scripts/run-local-acceptance-probe.sh /Applications/Delta.app."
fi

if [[ -f "$MANUAL_REPORT" ]]; then
  if "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" "$MANUAL_REPORT" >/dev/null 2>&1; then
    manual_commit="$(manual_report_value "Git Commit")"
    if [[ "$manual_commit" == "$head_commit" ]]; then
      pass "Manual acceptance report passes for current commit."
    else
      block "Manual acceptance report passes for $manual_commit, not current commit $head_commit."
    fi
  else
    block "Manual acceptance report has missing, failed, blocked, or malformed rows."
  fi
else
  block "Manual acceptance report is missing. Run Scripts/create-manual-acceptance-report.sh and complete the matrix."
fi

printf "\n## External Backend Acceptance Environment\n\n"
if [[ -n "${DELTA_ACCEPTANCE_MOUNTED_PATH:-}" ]]; then
  pass "Mounted network destination acceptance is configured."
else
  warn "Mounted SMB/NFS destination acceptance is not configured: set DELTA_ACCEPTANCE_MOUNTED_PATH."
fi
if [[ -n "${DELTA_ACCEPTANCE_SFTP_REPOSITORY:-}" ]]; then
  pass "SFTP destination acceptance is configured."
else
  warn "SFTP destination acceptance is not configured: set DELTA_ACCEPTANCE_SFTP_REPOSITORY."
fi
if [[ -n "${DELTA_ACCEPTANCE_S3_REPOSITORY:-}" ]]; then
  pass "S3-compatible destination acceptance is configured."
else
  warn "S3-compatible destination acceptance is not configured: set DELTA_ACCEPTANCE_S3_REPOSITORY plus provider credentials."
fi

additional_backends=0
for key in \
  DELTA_ACCEPTANCE_REST_REPOSITORY \
  DELTA_ACCEPTANCE_B2_REPOSITORY \
  DELTA_ACCEPTANCE_AZURE_REPOSITORY \
  DELTA_ACCEPTANCE_GCS_REPOSITORY \
  DELTA_ACCEPTANCE_SWIFT_REPOSITORY \
  DELTA_ACCEPTANCE_RCLONE_REPOSITORY \
  DELTA_ACCEPTANCE_CUSTOM_REPOSITORY
do
  if [[ -n "${!key:-}" ]]; then
    additional_backends=$((additional_backends + 1))
  fi
done
if [[ "$additional_backends" -gt 0 ]]; then
  pass "$additional_backends additional restic backend acceptance target(s) configured."
else
  warn "No additional restic backend acceptance targets are configured."
fi

printf "\n## Summary\n\n"
printf -- "- Blockers: %d\n" "$blockers"
printf -- "- Warnings: %d\n" "$warnings"
if [[ "$blockers" -eq 0 ]]; then
  printf -- "- Ready for production verification: Yes\n"
  exit 0
fi

printf -- "- Ready for production verification: No\n"
if [[ "${DELTA_DOCTOR_ALLOW_BLOCKERS:-0}" == "1" ]]; then
  exit 0
fi
exit 1
