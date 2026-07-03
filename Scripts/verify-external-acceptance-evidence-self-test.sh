#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_SCRIPT="$ROOT_DIR/Scripts/verify-external-acceptance-evidence.sh"
APP_PATH="${1:-$ROOT_DIR/dist/Delta.app}"

fail() {
  printf "External acceptance evidence self-test failed: %s\n" "$1" >&2
  exit 1
}

canonical_app_path() {
  local app="$1"
  [[ -d "$app" ]] || fail "app bundle not found at $app. Build Delta.app before running this self-test."
  (cd "$app" && /bin/pwd -P)
}

code_signature_value() {
  local app="$1"
  local key="$2"
  /usr/bin/codesign -dvvv "$app" 2>&1 | /usr/bin/awk -F= -v key="$key" '$1 == key && value == "" { value = $2 } END { print value }'
}

APP_PATH="$(canonical_app_path "$APP_PATH")"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
APP_RESTIC="$APP_PATH/Contents/MacOS/restic"
[[ -x "$APP_EXECUTABLE" ]] || fail "Delta executable missing at $APP_EXECUTABLE."
[[ -x "$APP_RESTIC" ]] || fail "bundled restic missing at $APP_RESTIC."
APP_CDHASH="$(code_signature_value "$APP_PATH" CDHash)"
[[ -n "$APP_CDHASH" ]] || fail "could not read app CDHash."
HEAD_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)"

WORK_DIR="$(/usr/bin/mktemp -d -t delta-external-evidence-self-test.XXXXXX)"
trap '/bin/rm -rf "$WORK_DIR"' EXIT

write_report() {
  local kind="$1"
  local environment="$2"
  local missing_credential_probe="$3"
  local bad_target_probe="$4"
  local report="$WORK_DIR/external-$kind-acceptance-latest.md"

  cat >"$report" <<EOF
# Delta Installed External Lifecycle Acceptance

- Generated: 2026-07-03T00:00:00Z
- Kind: $kind
- App: $APP_PATH
- Executable: $APP_EXECUTABLE
- Application Support: $WORK_DIR/support-$kind
- Restic: $APP_RESTIC
- Destination type: External acceptance
- Keychain credential references: 1

This verifies the installed Delta app's own coordinator against a configured external destination.

## Result

Installed external $kind lifecycle acceptance passed.

- Delta coordinator lifecycle: Yes
- Automatic destination preparation runs: 1
- Missing credential probe: $missing_credential_probe
- Wrong SFTP credential or target probe: $bad_target_probe
- First backup status: Completed
- No-change backup: 0 new, 0 changed, 4 unchanged
- Incremental backup: 1 new, 1 changed, 3 unchanged
- Cached restore points: 3
- Latest restore point: 0123456789abcdef
- Restore browser entries verified: 4
- Full restore status: Completed
- Selected folder restore status: Completed
- Destination check status: Completed
- Cleanup runs: Clean up old restore points Completed, Check destination Completed
- Stored backup jobs: 3
- Stored restore jobs: 2
- Keychain items deleted on exit: Yes

## Acceptance Provenance

- Runner: Scripts/run-external-backend-acceptance.sh
- Git Commit: $HEAD_COMMIT
- Acceptance environment: $environment
- App CDHash: $APP_CDHASH
EOF
}

write_good_reports() {
  write_report mounted mounted-network "Not configured" "Not configured"
  write_report sftp real-external "Not configured" "Passed"
  write_report s3 real-external "Passed" "Not configured"
}

run_verify() {
  DELTA_EXTERNAL_ACCEPTANCE_DIR="$WORK_DIR" \
    DELTA_EXTERNAL_ACCEPTANCE_GIT_COMMIT="$HEAD_COMMIT" \
    "$VERIFY_SCRIPT" "$APP_PATH"
}

expect_failure() {
  local name="$1"
  local expected="$2"
  shift 2
  local output
  set +e
  output="$("$@" 2>&1)"
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || fail "$name unexpectedly passed."
  if ! /usr/bin/grep -Fq "$expected" <<<"$output"; then
    printf "%s\n" "$output" >&2
    fail "$name failed without expected message: $expected"
  fi
}

write_good_reports
run_verify >/dev/null

write_good_reports
/usr/bin/perl -0pi -e 's#^- App: .*$#- App: /Applications/OtherDelta.app#m' "$WORK_DIR/external-s3-acceptance-latest.md"
expect_failure "mismatched app path" "expected '$APP_PATH'" run_verify

write_good_reports
/usr/bin/perl -0pi -e 's#^- App CDHash: .*$#- App CDHash: deadbeef#m' "$WORK_DIR/external-mounted-acceptance-latest.md"
expect_failure "mismatched app CDHash" "does not match $APP_PATH CDHash" run_verify

write_good_reports
/usr/bin/perl -0pi -e 's#^- Acceptance environment: real-external$#- Acceptance environment: local-harness#m' "$WORK_DIR/external-sftp-acceptance-latest.md"
expect_failure "local harness SFTP report" "Localhost/local harness evidence is not sufficient" run_verify

write_good_reports
/usr/bin/grep -Fv -- "- Stored backup jobs:" "$WORK_DIR/external-mounted-acceptance-latest.md" >"$WORK_DIR/mounted.tmp"
/bin/mv "$WORK_DIR/mounted.tmp" "$WORK_DIR/external-mounted-acceptance-latest.md"
expect_failure "missing stored job count" "Stored backup jobs: 3" run_verify

write_good_reports
/usr/bin/grep -Fv -- "- Executable:" "$WORK_DIR/external-mounted-acceptance-latest.md" >"$WORK_DIR/mounted.tmp"
/bin/mv "$WORK_DIR/mounted.tmp" "$WORK_DIR/external-mounted-acceptance-latest.md"
expect_failure "missing executable provenance" "mounted report at $WORK_DIR/external-mounted-acceptance-latest.md does not record 'Executable'." run_verify

expect_failure "missing app bundle" "app bundle not found" \
  env DELTA_EXTERNAL_ACCEPTANCE_DIR="$WORK_DIR" "$VERIFY_SCRIPT" "$WORK_DIR/Missing.app"

printf "External acceptance evidence self-test passed for %s.\n" "$APP_PATH"
