#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

/usr/bin/swift test

"$ROOT_DIR/Scripts/verify-product-language.sh"
"$ROOT_DIR/Scripts/verify-no-crash-markers.sh"
/bin/bash -n \
  "$ROOT_DIR/Scripts/package-update.sh" \
  "$ROOT_DIR/Scripts/notarize-release.sh" \
  "$ROOT_DIR/Scripts/verify-ci.sh" \
  "$ROOT_DIR/Scripts/verify-ci-workflows.sh" \
  "$ROOT_DIR/Scripts/verify-notarization-policy.sh" \
  "$ROOT_DIR/Scripts/manual-acceptance-items.sh" \
  "$ROOT_DIR/Scripts/collect-release-evidence.sh" \
  "$ROOT_DIR/Scripts/create-manual-acceptance-report.sh" \
  "$ROOT_DIR/Scripts/doctor-production-readiness.sh" \
  "$ROOT_DIR/Scripts/verify-installed-app.sh" \
  "$ROOT_DIR/Scripts/verify-manual-acceptance-matrix.sh" \
  "$ROOT_DIR/Scripts/verify-manual-acceptance-self-test.sh" \
  "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" \
  "$ROOT_DIR/Scripts/verify-sparkle-update-artifacts.sh" \
  "$ROOT_DIR/Scripts/verify-external-acceptance-evidence.sh" \
  "$ROOT_DIR/Scripts/preflight-external-backend-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-diagnostics-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-keychain-access-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-menu-bar-surface-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-mounted-volume-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-local-rest-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-local-s3-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-local-sftp-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-local-backup-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-preferences-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-rclone-local-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-run-control-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-installed-scheduled-agent-acceptance.sh" \
  "$ROOT_DIR/Scripts/run-local-acceptance-probe.sh" \
  "$ROOT_DIR/Scripts/verify-production-readiness.sh"
if [[ ! -x "$ROOT_DIR/Scripts/notarize-release.sh" ]]; then
  printf "Scripts/notarize-release.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-notarization-policy.sh" ]]; then
  printf "Scripts/verify-notarization-policy.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-ci.sh" ]]; then
  printf "Scripts/verify-ci.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-ci-workflows.sh" ]]; then
  printf "Scripts/verify-ci-workflows.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/collect-release-evidence.sh" ]]; then
  printf "Scripts/collect-release-evidence.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-installed-app.sh" ]]; then
  printf "Scripts/verify-installed-app.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/create-manual-acceptance-report.sh" ]]; then
  printf "Scripts/create-manual-acceptance-report.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/doctor-production-readiness.sh" ]]; then
  printf "Scripts/doctor-production-readiness.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-manual-acceptance.sh" ]]; then
  printf "Scripts/verify-manual-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-manual-acceptance-matrix.sh" ]]; then
  printf "Scripts/verify-manual-acceptance-matrix.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-manual-acceptance-self-test.sh" ]]; then
  printf "Scripts/verify-manual-acceptance-self-test.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-sparkle-update-artifacts.sh" ]]; then
  printf "Scripts/verify-sparkle-update-artifacts.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-external-acceptance-evidence.sh" ]]; then
  printf "Scripts/verify-external-acceptance-evidence.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-no-crash-markers.sh" ]]; then
  printf "Scripts/verify-no-crash-markers.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-local-acceptance-probe.sh" ]]; then
  printf "Scripts/run-local-acceptance-probe.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-local-backup-acceptance.sh" ]]; then
  printf "Scripts/run-installed-local-backup-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-menu-bar-surface-acceptance.sh" ]]; then
  printf "Scripts/run-installed-menu-bar-surface-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-mounted-volume-acceptance.sh" ]]; then
  printf "Scripts/run-installed-mounted-volume-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-local-s3-acceptance.sh" ]]; then
  printf "Scripts/run-installed-local-s3-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-local-sftp-acceptance.sh" ]]; then
  printf "Scripts/run-installed-local-sftp-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-local-rest-acceptance.sh" ]]; then
  printf "Scripts/run-installed-local-rest-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-preferences-acceptance.sh" ]]; then
  printf "Scripts/run-installed-preferences-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-rclone-local-acceptance.sh" ]]; then
  printf "Scripts/run-installed-rclone-local-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-run-control-acceptance.sh" ]]; then
  printf "Scripts/run-installed-run-control-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-scheduled-agent-acceptance.sh" ]]; then
  printf "Scripts/run-installed-scheduled-agent-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" ]]; then
  printf "Scripts/run-external-backend-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/preflight-external-backend-acceptance.sh" ]]; then
  printf "Scripts/preflight-external-backend-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-keychain-access-acceptance.sh" ]]; then
  printf "Scripts/run-installed-keychain-access-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-diagnostics-acceptance.sh" ]]; then
  printf "Scripts/run-installed-diagnostics-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-production-readiness.sh" ]]; then
  printf "Scripts/verify-production-readiness.sh must be executable.\n" >&2
  exit 1
fi
"$ROOT_DIR/Scripts/verify-manual-acceptance-matrix.sh"
"$ROOT_DIR/Scripts/verify-manual-acceptance-self-test.sh"
"$ROOT_DIR/Scripts/verify-notarization-policy.sh"
"$ROOT_DIR/Scripts/verify-ci-workflows.sh"
"$ROOT_DIR/Scripts/bootstrap-tools.sh"
"$ROOT_DIR/Scripts/verify-tools.sh"
"$ROOT_DIR/Scripts/verify-restic-surface.sh"

DELTA_RESTIC_INTEGRATION=1 \
RESTIC_BINARY="$ROOT_DIR/Resources/Tools/bin/restic" \
/usr/bin/swift test --filter ResticIntegrationTests

BUILD_LOG="$(/usr/bin/mktemp -t delta-build-app.XXXXXX)"
if ! "$ROOT_DIR/Scripts/build-app.sh" 2>&1 | /usr/bin/tee "$BUILD_LOG"; then
  /bin/rm -f "$BUILD_LOG"
  exit 1
fi
if /usr/bin/grep -q "warning:" "$BUILD_LOG"; then
  printf "Production app build emitted compiler warnings.\n" >&2
  /usr/bin/grep "warning:" "$BUILD_LOG" >&2
  /bin/rm -f "$BUILD_LOG"
  exit 1
fi
/bin/rm -f "$BUILD_LOG"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$ROOT_DIR/dist/Delta.app"

SIGNING_DETAILS="$(/usr/bin/codesign -dvv "$ROOT_DIR/dist/Delta.app" 2>&1)"
if ! /usr/bin/grep -q '^TeamIdentifier=' <<<"$SIGNING_DETAILS"; then
  printf "Delta.app is ad-hoc signed. Install an Apple Development or Developer ID certificate, or set DELTA_CODESIGN_IDENTITY, before release verification.\n" >&2
  exit 1
fi
if /usr/bin/grep -q '^TeamIdentifier=not set$' <<<"$SIGNING_DETAILS"; then
  printf "Delta.app has no TeamIdentifier. Stable macOS privacy permissions require a real signing identity.\n" >&2
  exit 1
fi

assert_no_runtime_exception_entitlements() {
  local target="$1"
  local entitlements
  entitlements="$(/usr/bin/codesign -d --entitlements :- "$target" 2>/dev/null || true)"
  for key in \
    "com.apple.security.cs.allow-jit" \
    "com.apple.security.cs.allow-unsigned-executable-memory" \
    "com.apple.security.cs.disable-library-validation"
  do
    if /usr/bin/grep -q "<key>$key</key>" <<<"$entitlements"; then
      printf "%s contains unnecessary hardened-runtime exception entitlement: %s\n" "$target" "$key" >&2
      exit 1
    fi
  done
}

assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaAgent"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaSecretBridge"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/restic"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/rclone"

if ! /usr/bin/otool -l "$ROOT_DIR/dist/Delta.app/Contents/MacOS/Delta" | /usr/bin/grep -q "@executable_path/../Frameworks"; then
  printf "Delta.app is missing the Frameworks runtime search path.\n" >&2
  exit 1
fi
if [[ ! -f "$ROOT_DIR/dist/Delta.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]; then
  printf "Delta.app is missing the embedded Sparkle framework binary.\n" >&2
  exit 1
fi
LAUNCH_AGENT_PLIST="$ROOT_DIR/dist/Delta.app/Contents/Library/LaunchAgents/com.delta.backup.agent.plist"
if [[ ! -f "$LAUNCH_AGENT_PLIST" ]]; then
  printf "Delta.app is missing the bundled LaunchAgent plist.\n" >&2
  exit 1
fi
/usr/bin/plutil -lint "$LAUNCH_AGENT_PLIST" >/dev/null
AGENT_BUNDLE_PROGRAM="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$LAUNCH_AGENT_PLIST")"
AGENT_LABEL="$(/usr/libexec/PlistBuddy -c 'Print :Label' "$LAUNCH_AGENT_PLIST")"
AGENT_PROCESS_TYPE="$(/usr/libexec/PlistBuddy -c 'Print :ProcessType' "$LAUNCH_AGENT_PLIST")"
AGENT_ASSOCIATED_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers:0' "$LAUNCH_AGENT_PLIST")"
if [[ "$AGENT_LABEL" != "com.delta.backup.agent" ]]; then
  printf "LaunchAgent label is invalid: %s\n" "$AGENT_LABEL" >&2
  exit 1
fi
if [[ "$AGENT_BUNDLE_PROGRAM" != "Contents/MacOS/DeltaAgent" || ! -x "$ROOT_DIR/dist/Delta.app/$AGENT_BUNDLE_PROGRAM" ]]; then
  printf "LaunchAgent BundleProgram is not executable: %s\n" "$AGENT_BUNDLE_PROGRAM" >&2
  exit 1
fi
if [[ "$AGENT_PROCESS_TYPE" != "Background" ]]; then
  printf "LaunchAgent ProcessType is invalid: %s\n" "$AGENT_PROCESS_TYPE" >&2
  exit 1
fi
if [[ "$AGENT_ASSOCIATED_BUNDLE" != "com.delta.backup" ]]; then
  printf "LaunchAgent associated bundle identifier is invalid: %s\n" "$AGENT_ASSOCIATED_BUNDLE" >&2
  exit 1
fi
AGENT_RUN_AT_LOAD="$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$LAUNCH_AGENT_PLIST")"
AGENT_START_INTERVAL="$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$LAUNCH_AGENT_PLIST")"
if [[ "$AGENT_RUN_AT_LOAD" != "true" || "$AGENT_START_INTERVAL" != "300" ]]; then
  printf "LaunchAgent schedule is invalid. RunAtLoad=%s StartInterval=%s\n" "$AGENT_RUN_AT_LOAD" "$AGENT_START_INTERVAL" >&2
  exit 1
fi
/usr/bin/codesign --verify --strict --verbose=2 "$ROOT_DIR/dist/Delta.app/$AGENT_BUNDLE_PROGRAM"
/usr/bin/codesign --verify --strict --verbose=2 "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaSecretBridge"

LAUNCH_LOG="$(/usr/bin/mktemp -t delta-launch-smoke.XXXXXX)"
"$ROOT_DIR/dist/Delta.app/Contents/MacOS/Delta" >"$LAUNCH_LOG" 2>&1 &
DELTA_PID=$!
/bin/sleep 2
if ! /bin/kill -0 "$DELTA_PID" >/dev/null 2>&1; then
  /bin/cat "$LAUNCH_LOG" >&2
  /bin/rm -f "$LAUNCH_LOG"
  exit 1
fi
/bin/kill "$DELTA_PID" >/dev/null 2>&1 || true
wait "$DELTA_PID" >/dev/null 2>&1 || true
/bin/rm -f "$LAUNCH_LOG"

DELTA_AGENT="$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaAgent"
"$DELTA_AGENT" --status
AGENT_DRY_RUN_OUTPUT="$("$DELTA_AGENT" --dry-run 2>&1)"
if [[ "$AGENT_DRY_RUN_OUTPUT" != *"dry run did not start scheduled backups"* ]]; then
  printf "DeltaAgent dry-run did not report non-mutating behavior: %s\n" "$AGENT_DRY_RUN_OUTPUT" >&2
  exit 1
fi
ISOLATED_AGENT_SUPPORT="$(/usr/bin/mktemp -d -t delta-agent-support.XXXXXX)"
set +e
AGENT_ISOLATED_OUTPUT="$(DELTA_APP_SUPPORT_DIR="$ISOLATED_AGENT_SUPPORT" "$DELTA_AGENT" 2>&1)"
AGENT_ISOLATED_STATUS=$?
set -e
if [[ "$AGENT_ISOLATED_STATUS" -ne 0 || "$AGENT_ISOLATED_OUTPUT" != *"completed 0 due backup run(s)"* ]]; then
  printf "DeltaAgent did not complete isolated no-profile due-run path. status=%s output=%s\n" "$AGENT_ISOLATED_STATUS" "$AGENT_ISOLATED_OUTPUT" >&2
  /bin/rm -rf "$ISOLATED_AGENT_SUPPORT"
  exit 1
fi
if [[ ! -f "$ISOLATED_AGENT_SUPPORT/Delta.sqlite" ]]; then
  printf "DeltaAgent did not create an isolated app database at %s\n" "$ISOLATED_AGENT_SUPPORT/Delta.sqlite" >&2
  /bin/rm -rf "$ISOLATED_AGENT_SUPPORT"
  exit 1
fi
/bin/rm -rf "$ISOLATED_AGENT_SUPPORT"
set +e
AGENT_UNSUPPORTED_OUTPUT="$("$DELTA_AGENT" --status --dry-run 2>&1)"
AGENT_UNSUPPORTED_STATUS=$?
set -e
if [[ "$AGENT_UNSUPPORTED_STATUS" -ne 64 || "$AGENT_UNSUPPORTED_OUTPUT" != *"unsupported arguments"* ]]; then
  printf "DeltaAgent did not fail closed for unsupported arguments. status=%s output=%s\n" "$AGENT_UNSUPPORTED_STATUS" "$AGENT_UNSUPPORTED_OUTPUT" >&2
  exit 1
fi
"$ROOT_DIR/dist/Delta.app/Contents/MacOS/restic" version
"$ROOT_DIR/dist/Delta.app/Contents/MacOS/rclone" version | /usr/bin/head -n 1

SECRET_BRIDGE="$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaSecretBridge"
set +e
SECRET_BRIDGE_MISSING_OUTPUT="$("$SECRET_BRIDGE" 2>&1)"
SECRET_BRIDGE_MISSING_STATUS=$?
SECRET_BRIDGE_EXTRA_OUTPUT="$("$SECRET_BRIDGE" account extra 2>&1)"
SECRET_BRIDGE_EXTRA_STATUS=$?
set -e
if [[ "$SECRET_BRIDGE_MISSING_STATUS" -ne 64 || "$SECRET_BRIDGE_MISSING_OUTPUT" != *"expected exactly one keychain account"* ]]; then
  printf "DeltaSecretBridge did not fail closed for a missing account. status=%s output=%s\n" "$SECRET_BRIDGE_MISSING_STATUS" "$SECRET_BRIDGE_MISSING_OUTPUT" >&2
  exit 1
fi
if [[ "$SECRET_BRIDGE_EXTRA_STATUS" -ne 64 || "$SECRET_BRIDGE_EXTRA_OUTPUT" != *"expected exactly one keychain account"* ]]; then
  printf "DeltaSecretBridge did not fail closed for extra arguments. status=%s output=%s\n" "$SECRET_BRIDGE_EXTRA_STATUS" "$SECRET_BRIDGE_EXTRA_OUTPUT" >&2
  exit 1
fi
"$ROOT_DIR/Scripts/run-installed-keychain-access-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-diagnostics-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-preferences-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-menu-bar-surface-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-scheduled-agent-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-run-control-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-mounted-volume-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-local-rest-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-local-s3-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-local-sftp-acceptance.sh" "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/run-installed-rclone-local-acceptance.sh" "$ROOT_DIR/dist/Delta.app"

DELTA_SKIP_BUILD=1 "$ROOT_DIR/Scripts/package-update.sh"
"$ROOT_DIR/Scripts/generate-appcast.sh"
"$ROOT_DIR/Scripts/verify-sparkle-update-artifacts.sh" "$ROOT_DIR/dist/Delta.app" "$ROOT_DIR/dist/updates"

GATE_STATUS_DIR="$ROOT_DIR/dist/release-evidence"
/bin/mkdir -p "$GATE_STATUS_DIR"
cat >"$GATE_STATUS_DIR/automated-gate-status" <<EOF
status=Passed
git_commit=$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")
generated_at=$(/bin/date -u +%Y%m%dT%H%M%SZ)
app_path=$ROOT_DIR/dist/Delta.app
EOF

printf "Release verification passed for %s\n" "$ROOT_DIR/dist/Delta.app"
