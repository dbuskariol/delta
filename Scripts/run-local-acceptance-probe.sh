#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_LOCAL_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"
GATE_STATUS_FILE="$ROOT_DIR/dist/release-evidence/automated-gate-status"

mkdir -p "$OUTPUT_DIR"

TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-local-acceptance-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/latest.md"
TMP_DIR="$(/usr/bin/mktemp -d -t delta-local-acceptance.XXXXXX)"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

pass_count=0
partial_count=0
manual_count=0
fail_count=0

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || printf "Unknown"
}

gate_status_value() {
  local key="$1"
  /usr/bin/awk -F= -v key="$key" '$1 == key { print $2; exit }' "$GATE_STATUS_FILE" 2>/dev/null || true
}

sanitize_cell() {
  printf "%s" "$1" \
    | /usr/bin/tr '\r\n\t' '   ' \
    | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/|/\\|/g' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //g' -e 's/ $//g'
}

append_row() {
  local id="$1"
  local area="$2"
  local status="$3"
  local automated_evidence="$4"
  local manual_followup="$5"

  case "$status" in
    "Automated Pass")
      pass_count=$((pass_count + 1))
      ;;
    "Partial")
      partial_count=$((partial_count + 1))
      ;;
    "Manual Required")
      manual_count=$((manual_count + 1))
      ;;
    "Failed")
      fail_count=$((fail_count + 1))
      ;;
    *)
      fail_count=$((fail_count + 1))
      status="Failed"
      automated_evidence="Invalid local acceptance status was produced."
      ;;
  esac

  printf '| %s | %s | %s | %s | %s |\n' \
    "$(sanitize_cell "$id")" \
    "$(sanitize_cell "$area")" \
    "$(sanitize_cell "$status")" \
    "$(sanitize_cell "$automated_evidence")" \
    "$(sanitize_cell "$manual_followup")" >>"$OUTPUT"
}

run_capture() {
  local name="$1"
  shift
  local output_file="$TMP_DIR/$name.out"
  set +e
  "$@" >"$output_file" 2>&1
  local status=$?
  set -e
  printf "%s" "$status" >"$TMP_DIR/$name.status"
  /usr/bin/head -n 12 "$output_file" | /usr/bin/tr '\n' ' '
}

command_status() {
  local name="$1"
  /bin/cat "$TMP_DIR/$name.status" 2>/dev/null || printf "1"
}

codesign_value_for_app() {
  local app="$1"
  local key="$2"
  /usr/bin/codesign -dvvv "$app" 2>&1 \
    | /usr/bin/awk -F= -v key="$key" '$1 == key && value == "" { value = $2 } END { print value }'
}

codesign_value() {
  local key="$1"
  codesign_value_for_app "$APP_PATH" "$key"
}

item_area() {
  local wanted_id="$1"
  /usr/bin/awk -F'\t' -v wanted_id="$wanted_id" '$1 == wanted_id { print $2; exit }' < <(manual_acceptance_items)
}

app_info_plist="$APP_PATH/Contents/Info.plist"
short_version="Unknown"
build_version="Unknown"
bundle_id="Unknown"
if [[ -f "$app_info_plist" ]]; then
  short_version="$(plist_value "$app_info_plist" CFBundleShortVersionString)"
  build_version="$(plist_value "$app_info_plist" CFBundleVersion)"
  bundle_id="$(plist_value "$app_info_plist" CFBundleIdentifier)"
fi
git_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")"

cat >"$OUTPUT" <<EOF
# Delta Local Acceptance Probe

- Generated: $TIMESTAMP UTC
- App: $APP_PATH
- Bundle ID: $bundle_id
- Version: $short_version
- Build: $build_version
- Git Commit: $git_commit
- Host macOS: $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))

This report captures evidence Delta can verify locally without human interaction. It does not replace the manual acceptance report. Rows marked \`Partial\` or \`Manual Required\` still need the human evidence described in \`Scripts/manual-acceptance-items.sh\` before \`Scripts/verify-production-readiness.sh\` can pass.

| ID | Area | Local Status | Automated Evidence | Manual Follow-Up |
| --- | --- | --- | --- | --- |
EOF

if [[ ! -d "$APP_PATH" ]]; then
  while IFS=$'\t' read -r id area _required_evidence; do
    append_row "$id" "$area" "Failed" "App bundle was not found at $APP_PATH." "Install the current release candidate into /Applications and rerun this probe."
  done < <(manual_acceptance_items)
else
  signing_output="$(run_capture codesign /usr/bin/codesign -dvv "$APP_PATH")"
  signing_status="$(command_status codesign)"
  verify_output="$(run_capture codesign_verify /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_PATH")"
  verify_status="$(command_status codesign_verify)"
  team_id="$(codesign_value TeamIdentifier)"
  cdhash="$(codesign_value CDHash)"
  authority="$(codesign_value Authority)"
  installed_match="No"
  installed_evidence="No installed /Applications/Delta.app was available for comparison."
  if [[ -d "/Applications/Delta.app" ]]; then
    installed_info_plist="/Applications/Delta.app/Contents/Info.plist"
    installed_cdhash="$(codesign_value_for_app "/Applications/Delta.app" CDHash)"
    installed_bundle_id="$(plist_value "$installed_info_plist" CFBundleIdentifier)"
    installed_short_version="$(plist_value "$installed_info_plist" CFBundleShortVersionString)"
    installed_build_version="$(plist_value "$installed_info_plist" CFBundleVersion)"
    if [[ "$installed_cdhash" == "$cdhash" \
      && "$installed_bundle_id" == "$bundle_id" \
      && "$installed_short_version" == "$short_version" \
      && "$installed_build_version" == "$build_version" ]]
    then
      installed_match="Yes"
    fi
    installed_evidence="/Applications/Delta.app match: $installed_match; installed version $installed_short_version ($installed_build_version), CDHash $installed_cdhash."
  fi
  if [[ "$verify_status" -eq 0 && -n "$team_id" && "$team_id" != "not set" && ( "$APP_PATH" == "/Applications/Delta.app" || "$installed_match" == "Yes" ) ]]; then
    append_row "install_identity" "$(item_area install_identity)" "Partial" "App verifies with Team ID $team_id, CDHash $cdhash, authority '$authority'. $installed_evidence" "Launch, quit, reinstall a same-identity build, relaunch, and confirm macOS privacy prompts stay stable."
  else
    append_row "install_identity" "$(item_area install_identity)" "Failed" "codesign verify status=$verify_status; Team ID='${team_id:-missing}'; app path=$APP_PATH; $installed_evidence output: $verify_output $signing_output" "Install a signed current build at /Applications/Delta.app and rerun."
  fi

  language_output="$(run_capture product_language "$ROOT_DIR/Scripts/verify-product-language.sh")"
  language_status="$(command_status product_language)"
  installed_diagnostics_output="$(run_capture installed_diagnostics "$ROOT_DIR/Scripts/run-installed-diagnostics-acceptance.sh" "$APP_PATH")"
  installed_diagnostics_status="$(command_status installed_diagnostics)"
  if [[ "$installed_diagnostics_status" -eq 0 ]]; then
    installed_diagnostics_evidence="Installed diagnostics acceptance passed: isolated installed-app diagnostic export generated a redacted report, proved Background Password Access was Ready, and proved seeded destination/backend credential values were absent. $installed_diagnostics_output"
  else
    installed_diagnostics_evidence="Installed diagnostics acceptance failed: $installed_diagnostics_output"
  fi

  if [[ "$language_status" -eq 0 && "$installed_diagnostics_status" -eq 0 ]]; then
    append_row "settings_surface" "$(item_area settings_surface)" "Partial" "Product-language verifier passed; raw Repository/LaunchAgent terminology is blocked from user-facing strings. Installed diagnostics reported Background Password Access as Ready." "Open Settings and confirm visual grouping, status summary, Run Due Now scheduler action, Sparkle automatic check/download controls, idle-sleep protection, reset controls, backup freshness warnings, source-access warnings, destination-check warning controls, and activity history retention in the running app."
  elif [[ "$language_status" -eq 0 ]]; then
    append_row "settings_surface" "$(item_area settings_surface)" "Failed" "Product-language verifier passed, but installed diagnostics did not prove Background Password Access: $installed_diagnostics_evidence" "Fix installed diagnostics and background password-access health before manual Settings acceptance."
  else
    append_row "settings_surface" "$(item_area settings_surface)" "Failed" "Product-language verifier failed: $language_output" "Fix user-facing terminology and rerun."
  fi

  append_row "full_disk_access" "$(item_area full_disk_access)" "Manual Required" "macOS Full Disk Access is tied to the app identity and cannot be safely proven by this shell process." "Use Settings > Full Disk Access, add Delta manually if needed, recheck access, and confirm dashboard readiness behavior."

  agent="$APP_PATH/Contents/MacOS/DeltaAgent"
  if [[ -x "$agent" ]]; then
    agent_status_output="$(run_capture agent_status "$agent" --status)"
    agent_status_status="$(command_status agent_status)"
    agent_dry_output="$(run_capture agent_dry "$agent" --dry-run)"
    agent_dry_status="$(command_status agent_dry)"
    isolated_support="$TMP_DIR/agent-support"
    agent_due_output="$(run_capture agent_due /bin/sh -c "DELTA_APP_SUPPORT_DIR='$isolated_support' '$agent' && test -f '$isolated_support/Delta.sqlite'")"
    agent_due_status="$(command_status agent_due)"
    scheduled_agent_output="$(run_capture scheduled_agent "$ROOT_DIR/Scripts/run-installed-scheduled-agent-acceptance.sh" "$APP_PATH")"
    scheduled_agent_status="$(command_status scheduled_agent)"
    if [[ "$agent_status_status" -eq 0 && "$agent_dry_status" -eq 0 && "$agent_due_status" -eq 0 && "$scheduled_agent_status" -eq 0 ]]; then
      append_row "background_backups" "$(item_area background_backups)" "Partial" "Helper status, dry-run, no-profile isolated due-run, and seeded scheduled-helper backup acceptance passed: $agent_status_output $agent_dry_output $agent_due_output $scheduled_agent_output" "Approve Login Items if macOS asks, quit Delta, wait for a real scheduled interval, and confirm the run appears after relaunch."
    else
      append_row "background_backups" "$(item_area background_backups)" "Failed" "Helper checks failed. status=$agent_status_status dry=$agent_dry_status due=$agent_due_status scheduled=$scheduled_agent_status output: $agent_status_output $agent_dry_output $agent_due_output $scheduled_agent_output" "Fix bundled Background Backups helper before manual schedule testing."
    fi
  else
    append_row "background_backups" "$(item_area background_backups)" "Failed" "DeltaAgent was not executable at $agent." "Rebuild and reinstall the app bundle."
  fi

  bridge="$APP_PATH/Contents/MacOS/DeltaSecretBridge"
  if [[ -x "$bridge" ]]; then
    bridge_output="$(run_capture secret_bridge /bin/sh -c "'$bridge' 2>&1; test \$? -eq 64")"
    bridge_status="$(command_status secret_bridge)"
    installed_keychain_output="$(run_capture installed_keychain_access "$ROOT_DIR/Scripts/run-installed-keychain-access-acceptance.sh" "$APP_PATH")"
    installed_keychain_status="$(command_status installed_keychain_access)"
    if [[ "$bridge_status" -eq 0 && "$installed_keychain_status" -eq 0 && "$installed_diagnostics_status" -eq 0 ]]; then
      append_row "keychain_background_access" "$(item_area keychain_background_access)" "Partial" "Secret bridge fail-closed argument behavior passed, installed Keychain access acceptance proved a throwaway destination password can be read by Delta --secret-bridge without interaction, and installed diagnostics proved Background Password Access as Ready for a destination with backend credentials: $bridge_output $installed_keychain_output $installed_diagnostics_output" "Run scheduled backups against saved app-managed and credentialed destinations and confirm Keychain does not prompt."
    elif [[ "$bridge_status" -eq 0 && "$installed_keychain_status" -eq 0 ]]; then
      append_row "keychain_background_access" "$(item_area keychain_background_access)" "Failed" "Secret bridge and installed Keychain access acceptance passed, but installed diagnostics did not prove Background Password Access readiness: $installed_diagnostics_evidence" "Fix background password-access diagnostics before scheduled-secret testing."
    elif [[ "$bridge_status" -eq 0 ]]; then
      append_row "keychain_background_access" "$(item_area keychain_background_access)" "Failed" "Secret bridge fail-closed argument behavior passed, but installed non-interactive Keychain access failed: $installed_keychain_output" "Fix the Keychain trusted-app access list or signed app identity before scheduled-secret testing."
    else
      append_row "keychain_background_access" "$(item_area keychain_background_access)" "Failed" "Secret bridge fail-closed check failed: $bridge_output" "Fix secret bridge argument handling before scheduled-secret testing."
    fi
  else
    append_row "keychain_background_access" "$(item_area keychain_background_access)" "Failed" "DeltaSecretBridge was not executable at $bridge." "Rebuild and reinstall the app bundle."
  fi

  installed_local_output="$(run_capture installed_local_backup "$ROOT_DIR/Scripts/run-installed-local-backup-acceptance.sh" "$APP_PATH")"
  installed_local_status="$(command_status installed_local_backup)"
  if [[ "$installed_local_status" -eq 0 ]]; then
    installed_local_evidence="Installed app local lifecycle acceptance passed through Delta coordinator: automatic destination preparation, first backup, no-change backup, incremental backup, restore-point cache, browser listing, full restore, selected folder restore, selected file restore, check, cleanup, and post-cleanup check. $installed_local_output"
  else
    installed_local_evidence="Installed app local lifecycle acceptance failed: $installed_local_output"
  fi

  mounted_acceptance_status="not_configured"
  mounted_acceptance_evidence=""
  if [[ -n "${DELTA_ACCEPTANCE_MOUNTED_PATH:-}" ]]; then
    mounted_output="$(run_capture external_mounted "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" mounted "$APP_PATH")"
    mounted_status="$(command_status external_mounted)"
    if [[ "$mounted_status" -eq 0 ]]; then
      mounted_acceptance_status="passed"
      mounted_acceptance_evidence="Installed Delta external mounted-destination lifecycle acceptance passed through the coordinator using configured /Volumes target: $mounted_output"
    else
      mounted_acceptance_status="failed"
      mounted_acceptance_evidence="External mounted-destination acceptance failed: $mounted_output"
    fi
  fi

  sftp_acceptance_status="not_configured"
  sftp_acceptance_evidence=""
  if [[ -n "${DELTA_ACCEPTANCE_SFTP_REPOSITORY:-}" ]]; then
    sftp_output="$(run_capture external_sftp "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" sftp "$APP_PATH")"
    sftp_status="$(command_status external_sftp)"
    if [[ "$sftp_status" -eq 0 ]]; then
      sftp_acceptance_status="passed"
      sftp_acceptance_evidence="Installed Delta external SFTP lifecycle acceptance passed through the coordinator with non-interactive authentication: $sftp_output"
    else
      sftp_acceptance_status="failed"
      sftp_acceptance_evidence="External SFTP acceptance failed: $sftp_output"
    fi
  fi

  s3_acceptance_status="not_configured"
  s3_acceptance_evidence=""
  if [[ -n "${DELTA_ACCEPTANCE_S3_REPOSITORY:-}" ]]; then
    s3_output="$(run_capture external_s3 "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" s3 "$APP_PATH")"
    s3_status="$(command_status external_s3)"
    if [[ "$s3_status" -eq 0 ]]; then
      s3_acceptance_status="passed"
      s3_acceptance_evidence="Installed Delta external S3-compatible lifecycle acceptance passed through the coordinator with Keychain-backed backend credentials, missing-credential failure, and corrected-credential success: $s3_output"
    else
      s3_acceptance_status="failed"
      s3_acceptance_evidence="External S3-compatible acceptance failed: $s3_output"
    fi
  fi

  automated_gate_status="$(gate_status_value status)"
  automated_gate_commit="$(gate_status_value git_commit)"
  if [[ "$automated_gate_status" == "Passed" && "$automated_gate_commit" == "$git_commit" ]]; then
    if [[ "$installed_local_status" -eq 0 ]]; then
      append_row "local_drive_destination" "$(item_area local_drive_destination)" "Partial" "$installed_local_evidence Automated release gate also passed local restic lifecycle, source access preflight, and destination write-probe coverage for commit $git_commit." "Repeat through the installed app UI with the target local or external drive."
      append_row "restore_wizard" "$(item_area restore_wizard)" "Partial" "$installed_local_evidence Automated release gate also passed dry-run restore command paths for commit $git_commit." "Exercise the installed Restore wizard UI, original-path confirmation, browser selection, and each overwrite policy."
    else
      append_row "local_drive_destination" "$(item_area local_drive_destination)" "Failed" "$installed_local_evidence" "Fix installed app local lifecycle acceptance, then repeat through the installed app UI."
      append_row "restore_wizard" "$(item_area restore_wizard)" "Failed" "$installed_local_evidence" "Fix installed app restore acceptance, then exercise the installed Restore wizard UI."
    fi
    append_row "new_backup_defaults" "$(item_area new_backup_defaults)" "Partial" "Automated release gate passed backup-default preference, health-threshold normalization, source-access dashboard health evaluation, and schedule policy tests for commit $git_commit." "Change defaults in Settings and confirm newly-created UI profiles inherit them without mutating existing profiles. Confirm Health Monitoring thresholds change dashboard attention timing without mutating profiles."
    append_row "restore_defaults" "$(item_area restore_defaults)" "Partial" "Automated release gate passed restore-default preference normalization, shared-settings reads, diagnostic summaries, and restore command safety coverage for commit $git_commit." "Change Settings > Restore Defaults, reopen Restore, and confirm defaults apply while remaining editable."
    append_row "browse_restore_points" "$(item_area browse_restore_points)" "Partial" "Automated release gate passed restore-point parsing, cache replacement, newest-first reads, and browser path command validation for commit $git_commit." "Open Restore, confirm restore points load on tab selection, refresh returns all current points, and pruned points disappear."
    append_row "pause_resume_cancel" "$(item_area pause_resume_cancel)" "Partial" "Automated release gate passed durable run-control and stopped-job model coverage for commit $git_commit." "Pause, resume, and cancel a real large backup from the main app and menu bar."
    append_row "streaming_logs" "$(item_area streaming_logs)" "Partial" "Automated release gate passed log formatting and persistence coverage for commit $git_commit." "Watch a real large backup and confirm fixed-height live logs, auto-scroll, source context, and expandable saved job logs."
    if [[ "$installed_diagnostics_status" -eq 0 ]]; then
      append_row "diagnostics_redaction" "$(item_area diagnostics_redaction)" "Partial" "$installed_diagnostics_evidence Automated release gate also passed diagnostic redaction coverage for commit $git_commit." "Copy and export a report from Settings and manually confirm no secrets appear."
    else
      append_row "diagnostics_redaction" "$(item_area diagnostics_redaction)" "Failed" "$installed_diagnostics_evidence" "Fix installed-app diagnostics export and redaction, then copy/export diagnostics from Settings."
    fi
  else
    gate_evidence="Automated release gate is not passed for current commit $git_commit. Recorded status='${automated_gate_status:-missing}' commit='${automated_gate_commit:-missing}'."
    append_row "local_drive_destination" "$(item_area local_drive_destination)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then repeat through the installed app UI."
    append_row "restore_wizard" "$(item_area restore_wizard)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then exercise the installed Restore wizard UI."
    append_row "new_backup_defaults" "$(item_area new_backup_defaults)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then verify Settings defaults in the UI."
    append_row "restore_defaults" "$(item_area restore_defaults)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then verify restore defaults in the UI."
    append_row "browse_restore_points" "$(item_area browse_restore_points)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then verify restore-point browsing in the UI."
    append_row "pause_resume_cancel" "$(item_area pause_resume_cancel)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then test real pause/resume/cancel behavior."
    append_row "streaming_logs" "$(item_area streaming_logs)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then watch a real large backup."
    append_row "diagnostics_redaction" "$(item_area diagnostics_redaction)" "Failed" "$gate_evidence" "Run Scripts/verify-release.sh, then export diagnostics from Settings."
  fi

  case "$mounted_acceptance_status" in
    passed)
      append_row "mounted_network_drive" "$(item_area mounted_network_drive)" "Partial" "$mounted_acceptance_evidence" "Disconnect and reconnect the mounted destination in the installed app UI; confirm Delta fails before invoking restic while disconnected and resumes after reconnect."
      ;;
    failed)
      append_row "mounted_network_drive" "$(item_area mounted_network_drive)" "Failed" "$mounted_acceptance_evidence" "Fix the configured mounted /Volumes acceptance target and rerun."
      ;;
    *)
      append_row "mounted_network_drive" "$(item_area mounted_network_drive)" "Manual Required" "No mounted SMB/NFS target is configured for non-interactive verification. Set DELTA_ACCEPTANCE_MOUNTED_PATH to run external backend acceptance. Automated local tests cover missing and unwritable local destination preflight with a real write/delete probe." "Test a mounted /Volumes destination, disconnect, confirm Delta fails before invoking restic, reconnect, resume, then repeat with an unwritable mount."
      ;;
  esac

  case "$sftp_acceptance_status" in
    passed)
      append_row "sftp_destination" "$(item_area sftp_destination)" "Partial" "$sftp_acceptance_evidence" "Repeat through the installed app UI and confirm restore-point refresh, restore, and wrong credential/key behavior if DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY was not configured."
      ;;
    failed)
      append_row "sftp_destination" "$(item_area sftp_destination)" "Failed" "$sftp_acceptance_evidence" "Fix the configured SFTP acceptance target and rerun."
      ;;
    *)
      append_row "sftp_destination" "$(item_area sftp_destination)" "Manual Required" "No real SFTP server/key pair is configured for non-interactive verification. Set DELTA_ACCEPTANCE_SFTP_REPOSITORY and optional DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY to run external backend acceptance." "Test wrong and corrected credentials, backup, restore-point refresh, and restore against SFTP."
      ;;
  esac

  case "$s3_acceptance_status" in
    passed)
      append_row "s3_destination" "$(item_area s3_destination)" "Partial" "$s3_acceptance_evidence" "Repeat through the installed app UI and confirm provider-specific credential entry, backup, check, restore-point refresh, and restore."
      ;;
    failed)
      append_row "s3_destination" "$(item_area s3_destination)" "Failed" "$s3_acceptance_evidence" "Fix the configured S3-compatible acceptance target and rerun."
      ;;
    *)
      append_row "s3_destination" "$(item_area s3_destination)" "Manual Required" "No S3-compatible provider credentials are configured for non-interactive verification. Set DELTA_ACCEPTANCE_S3_REPOSITORY plus AWS credentials to run external backend acceptance." "Test missing and corrected credentials, backup, check, restore-point refresh, and restore against S3-compatible storage."
      ;;
  esac

  remote_evidence_parts=()
  remote_failed_parts=()
  if [[ "$sftp_acceptance_status" == "passed" ]]; then
    remote_evidence_parts+=("Installed Delta SFTP external lifecycle acceptance proved unprepared-destination probe, prepare, reuse probe, backup, restore, check, and prune.")
  elif [[ "$sftp_acceptance_status" == "failed" ]]; then
    remote_failed_parts+=("$sftp_acceptance_evidence")
  fi
  if [[ "$s3_acceptance_status" == "passed" ]]; then
    remote_evidence_parts+=("Installed Delta S3-compatible external lifecycle acceptance proved Keychain-backed credentials, unprepared-destination probe, prepare, reuse probe, backup, restore, check, and prune.")
  elif [[ "$s3_acceptance_status" == "failed" ]]; then
    remote_failed_parts+=("$s3_acceptance_evidence")
  fi

  if [[ "${#remote_failed_parts[@]}" -gt 0 ]]; then
    append_row "remote_first_backup_preparation" "$(item_area remote_first_backup_preparation)" "Failed" "${remote_failed_parts[*]}" "Fix configured external remote acceptance targets and rerun."
  elif [[ "${#remote_evidence_parts[@]}" -gt 0 ]]; then
    append_row "remote_first_backup_preparation" "$(item_area remote_first_backup_preparation)" "Partial" "${remote_evidence_parts[*]}" "Repeat through the installed app UI with a new unprepared remote and an existing remote; confirm init happens only when needed."
  else
    append_row "remote_first_backup_preparation" "$(item_area remote_first_backup_preparation)" "Manual Required" "Remote destination preparation needs a real unprepared remote and an existing remote to avoid false confidence. Configure SFTP or S3 external acceptance to automate the backend lifecycle." "Start backup on new unprepared remote and existing remote; confirm init happens only when needed."
  fi
  append_row "menu_bar" "$(item_area menu_bar)" "Manual Required" "Native status item presentation and persistent popover behavior require visual macOS interaction." "Enable/disable the menu bar item and verify ready/running/attention states plus all popover actions."
  if [[ "$automated_gate_status" == "Passed" && "$automated_gate_commit" == "$git_commit" ]] \
    && grep -Fq "Send Test Alert" "$ROOT_DIR/Sources/Delta/ContentView.swift" \
    && grep -Fq "testTestAlertRequiresEnabledNotificationsAndDeliverableAuthorization" "$ROOT_DIR/Tests/DeltaCoreTests/JobNotificationPolicyTests.swift"
  then
    append_row "notifications" "$(item_area notifications)" "Partial" "Automated release gate passed notification policy coverage for commit $git_commit, and Settings exposes a Send Test Alert control for user-verifiable macOS delivery." "Enable alerts, grant macOS permission, use Send Test Alert, trigger warning/failed helper jobs, and verify success summaries only when opted in."
  else
    append_row "notifications" "$(item_area notifications)" "Manual Required" "Notification Center authorization and delivery require user approval and real macOS delivery." "Enable alerts, grant macOS permission, trigger warning/failed helper jobs, and verify success summaries only when opted in."
  fi

  sparkle_output="$(run_capture sparkle_artifacts "$ROOT_DIR/Scripts/verify-sparkle-update-artifacts.sh" "$ROOT_DIR/dist/Delta.app" "$ROOT_DIR/dist/updates")"
  sparkle_status="$(command_status sparkle_artifacts)"
  if [[ "$sparkle_status" -eq 0 ]]; then
    append_row "sparkle_update_install" "$(item_area sparkle_update_install)" "Partial" "Sparkle update artifact verification passed for the packaged app, archive, release notes, signed appcast enclosure, extracted bundle identity, and extracted bundle code signature: $sparkle_output" "Install an older signed build from the appcast, update through Sparkle, and confirm state survives."
  else
    append_row "sparkle_update_install" "$(item_area sparkle_update_install)" "Failed" "Sparkle update artifact verification failed: $sparkle_output" "Run Scripts/verify-release.sh or Scripts/generate-appcast.sh, then perform an actual update install."
  fi

  notarization_output="$(run_capture notarization /bin/sh -c "/usr/bin/codesign -dvv '$APP_PATH' 2>&1 | /usr/bin/grep -q '^Authority=Developer ID Application:' && /usr/bin/stapler validate '$APP_PATH' >/dev/null 2>&1 && /usr/sbin/spctl --assess --type execute '$APP_PATH' >/dev/null 2>&1")"
  notarization_status="$(command_status notarization)"
  if [[ "$notarization_status" -eq 0 ]]; then
    append_row "developer_id_notarization" "$(item_area developer_id_notarization)" "Automated Pass" "Developer ID signature, stapled ticket, and Gatekeeper assessment passed." "Archive notarytool submission and log JSON with the release evidence."
  else
    append_row "developer_id_notarization" "$(item_area developer_id_notarization)" "Failed" "Developer ID signature, stapled ticket, or Gatekeeper assessment is missing. $notarization_output" "Sign with Developer ID, submit with notarytool, staple, and rerun production readiness."
  fi
fi

cat >>"$OUTPUT" <<EOF

## Summary

- Automated pass: $pass_count
- Partial automated evidence: $partial_count
- Manual required: $manual_count
- Failed: $fail_count

Production readiness still requires the canonical manual acceptance report to be filled with human evidence and verified by \`Scripts/verify-manual-acceptance.sh\`.
EOF

LATEST_TMP="$OUTPUT_DIR/.latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote local acceptance probe to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Local acceptance summary: %d automated pass, %d partial, %d manual required, %d failed.\n" \
  "$pass_count" "$partial_count" "$manual_count" "$fail_count"

if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
