#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"
cd "$ROOT_DIR"

while IFS= read -r -d '' script; do
  /bin/bash -n "$script"
done < <(/usr/bin/find "$ROOT_DIR/Scripts" -type f -name '*.sh' -print0)
/usr/bin/xcrun swiftc -typecheck "$ROOT_DIR/Scripts/sparkle-public-key.swift"
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/Delta.app.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/Delta.entitlements" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/DeltaTimeMachineService.entitlements" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/com.delta.backup.agent.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/DeltaTimeMachineFS.Info.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/DeltaTimeMachineFS.entitlements" >/dev/null
if [[ "$(delta_plist_value 'com.apple.security.app-sandbox' "$ROOT_DIR/Packaging/DeltaTimeMachineFS.entitlements")" != "true" ]]; then
  delta_fail 'the Time Machine extension must declare the App Sandbox entitlement'
fi
for entitlement_file in \
  "$ROOT_DIR/Packaging/Delta.entitlements" \
  "$ROOT_DIR/Packaging/DeltaTimeMachineService.entitlements" \
  "$ROOT_DIR/Packaging/DeltaTimeMachineFS.entitlements"
do
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$entitlement_file")" == "BJCVJ5G7MJ.deltatm" ]]
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:1' "$entitlement_file" >/dev/null 2>&1; then
    printf "A Time Machine component declares an unexpected additional App Group: %s\n" "$entitlement_file" >&2
    exit 1
  fi
done
if /usr/bin/grep -Eq 'com\.apple\.security\.(network\.(client|server)|temporary-exception)' \
    "$ROOT_DIR/Packaging/DeltaTimeMachineFS.entitlements"; then
  printf "The Time Machine extension entitlements exceed its local App Group IPC boundary.\n" >&2
  exit 1
fi
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/DeltaTimeMachineHelper.Info.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/com.delta.backup.timemachine.service.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Packaging/com.delta.backup.timemachine.helper.plist" >/dev/null
/usr/bin/plutil -lint "$ROOT_DIR/Resources/PrivacyInfo.xcprivacy" >/dev/null
/usr/bin/git -C "$ROOT_DIR" diff --check
IFS=$'\t' read -r VERSION BUILD < <(delta_assert_release_metadata "$ROOT_DIR")

SIGNED_NOTES_FIXTURE="$(/usr/bin/mktemp -t delta-signed-release-notes.XXXXXX)"
printf '%s\n' \
  '<!-- sparkle-sign-warning:' \
  'This comment is prepended by Sparkle when release notes are signed.' \
  '-->' \
  "# Delta $VERSION" \
  >"$SIGNED_NOTES_FIXTURE"
[[ "$(delta_first_markdown_heading "$SIGNED_NOTES_FIXTURE")" == "# Delta $VERSION" ]]
/bin/rm -f "$SIGNED_NOTES_FIXTURE"

/usr/bin/swift test

"$ROOT_DIR/Scripts/verify-product-language.sh"
"$ROOT_DIR/Scripts/verify-no-crash-markers.sh"
DELTA_FORCE_SYSTEM_GREP_CRASH_SCAN=1 "$ROOT_DIR/Scripts/verify-no-crash-markers.sh"
"$ROOT_DIR/Scripts/verify-notarization-policy.sh"
"$ROOT_DIR/Scripts/notarization-artifact-contract-self-test.sh"
"$ROOT_DIR/Scripts/verify-manual-acceptance-matrix.sh"
"$ROOT_DIR/Scripts/verify-manual-acceptance-self-test.sh"
"$ROOT_DIR/Scripts/manual-acceptance-status-self-test.sh"
"$ROOT_DIR/Scripts/record-manual-acceptance-result-self-test.sh"
"$ROOT_DIR/Scripts/verify-ci-workflows.sh"
if [[ ! -x "$ROOT_DIR/Scripts/preflight-external-backend-acceptance.sh" ]]; then
  printf "Scripts/preflight-external-backend-acceptance.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-external-acceptance-evidence.sh" ]]; then
  printf "Scripts/verify-external-acceptance-evidence.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/verify-external-acceptance-evidence-self-test.sh" ]]; then
  printf "Scripts/verify-external-acceptance-evidence-self-test.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/manual-acceptance-status.sh" ]]; then
  printf "Scripts/manual-acceptance-status.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/manual-acceptance-status-self-test.sh" ]]; then
  printf "Scripts/manual-acceptance-status-self-test.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/record-manual-acceptance-result.sh" ]]; then
  printf "Scripts/record-manual-acceptance-result.sh must be executable.\n" >&2
  exit 1
fi
if [[ ! -x "$ROOT_DIR/Scripts/record-manual-acceptance-result-self-test.sh" ]]; then
  printf "Scripts/record-manual-acceptance-result-self-test.sh must be executable.\n" >&2
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
if [[ ! -x "$ROOT_DIR/Scripts/run-installed-rclone-local-acceptance.sh" ]]; then
  printf "Scripts/run-installed-rclone-local-acceptance.sh must be executable.\n" >&2
  exit 1
fi

"$ROOT_DIR/Scripts/bootstrap-tools.sh"
"$ROOT_DIR/Scripts/verify-tools.sh"
"$ROOT_DIR/Scripts/verify-restic-surface.sh"

DELTA_RESTIC_INTEGRATION=1 \
RESTIC_BINARY="$ROOT_DIR/Resources/Tools/bin/restic" \
/usr/bin/swift test --filter ResticIntegrationTests

DELTA_RCLONE_INTEGRATION=1 \
RCLONE_BINARY="$ROOT_DIR/Resources/Tools/bin/rclone" \
/usr/bin/swift test --filter TimeMachineRcloneIntegrationTests

BUILD_LOG="$(/usr/bin/mktemp -t delta-ci-build-app.XXXXXX)"
if ! DELTA_CODESIGN_IDENTITY="-" "$ROOT_DIR/Scripts/build-app.sh" 2>&1 | /usr/bin/tee "$BUILD_LOG"; then
  /bin/rm -f "$BUILD_LOG"
  exit 1
fi
if /usr/bin/grep -q "warning:" "$BUILD_LOG"; then
  printf "CI app build emitted compiler warnings.\n" >&2
  /usr/bin/grep "warning:" "$BUILD_LOG" >&2
  /bin/rm -f "$BUILD_LOG"
  exit 1
fi
/bin/rm -f "$BUILD_LOG"

/usr/bin/codesign --verify --strict --deep --verbose=2 "$ROOT_DIR/dist/Delta.app"
delta_assert_certificate_free_fskit_extension "$ROOT_DIR/dist/Delta.app"
"$ROOT_DIR/Scripts/certificate-free-fskit-contract-self-test.sh" "$ROOT_DIR/dist/Delta.app"
delta_record_automated_gate_status "$ROOT_DIR" "$ROOT_DIR/dist/Delta.app" "ci-self-test"
GATE_STATUS_FILE="$ROOT_DIR/dist/release-evidence/automated-gate-status"
GATE_APP_CDHASH="$(delta_signature_cdhash "$ROOT_DIR/dist/Delta.app")"
[[ "$(/usr/bin/awk -F= '$1 == "status" { print $2; exit }' "$GATE_STATUS_FILE")" == "Passed" ]]
[[ "$(/usr/bin/awk -F= '$1 == "git_commit" { print $2; exit }' "$GATE_STATUS_FILE")" == "$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD)" ]]
[[ "$(/usr/bin/awk -F= '$1 == "app_cdhash" { print $2; exit }' "$GATE_STATUS_FILE")" == "$GATE_APP_CDHASH" ]]
[[ "$(/usr/bin/awk -F= '$1 == "mode" { print $2; exit }' "$GATE_STATUS_FILE")" == "ci-self-test" ]]
/bin/rm -f "$GATE_STATUS_FILE"
"$ROOT_DIR/Scripts/verify-external-acceptance-evidence-self-test.sh" "$ROOT_DIR/dist/Delta.app"

INFO="$ROOT_DIR/dist/Delta.app/Contents/Info.plist"
SOURCE_INFO="$ROOT_DIR/Packaging/Delta.app.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_INFO")" == '$(MARKETING_VERSION)' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_INFO")" == '$(CURRENT_PROJECT_VERSION)' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "com.delta.backup" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" == "$VERSION" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" == "$BUILD" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")" == "$DELTA_EXPECTED_MINIMUM_SYSTEM" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO")" == "$DELTA_EXPECTED_FEED_URL" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO")" == "true" ]]
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")"
[[ "$PUBLIC_KEY" =~ ^[A-Za-z0-9+/=]{40,}$ ]]

PRIVACY_MANIFEST="$ROOT_DIR/dist/Delta.app/Contents/Resources/PrivacyInfo.xcprivacy"
[[ -f "$PRIVACY_MANIFEST" ]]
/usr/bin/plutil -lint "$PRIVACY_MANIFEST" >/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$PRIVACY_MANIFEST")" == "false" ]]
[[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes raw -o - "$PRIVACY_MANIFEST")" == "0" ]]
[[ "$(/usr/bin/plutil -extract NSPrivacyTrackingDomains raw -o - "$PRIVACY_MANIFEST")" == "0" ]]

HOST_ARCH="$(/usr/bin/uname -m)"
for EXECUTABLE_PATH in \
  "$ROOT_DIR/dist/Delta.app/Contents/MacOS/Delta" \
  "$ROOT_DIR/dist/Delta.app/Contents/Resources/DeltaAgent" \
  "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaSecretBridge" \
  "$ROOT_DIR/dist/Delta.app/Contents/Resources/DeltaTimeMachineService" \
  "$ROOT_DIR/dist/Delta.app/Contents/Library/LaunchServices/DeltaTimeMachineHelper" \
  "$ROOT_DIR/dist/Delta.app/Contents/Extensions/DeltaTimeMachineFS.appex/Contents/MacOS/DeltaTimeMachineFS" \
  "$ROOT_DIR/dist/Delta.app/Contents/MacOS/restic" \
  "$ROOT_DIR/dist/Delta.app/Contents/MacOS/rclone"
do
  [[ -x "$EXECUTABLE_PATH" ]]
  ARCHITECTURES="$(/usr/bin/lipo -archs "$EXECUTABLE_PATH")"
  [[ " $ARCHITECTURES " == *" $HOST_ARCH "* ]]
done
AGENT_PLIST="$ROOT_DIR/dist/Delta.app/Contents/Library/LaunchAgents/com.delta.backup.agent.plist"
[[ -f "$AGENT_PLIST" ]]
[[ "$(/usr/bin/plutil -extract BundleProgram raw -o - "$AGENT_PLIST")" == "Contents/Resources/DeltaAgent" ]]
[[ ! -e "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaAgent" ]]
[[ -x "$ROOT_DIR/dist/Delta.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]

# Shipping packagers reject this ad-hoc app; CI verifies that the boundary is
# fail-closed rather than weakening release validation for convenience.
if DELTA_SKIP_BUILD=1 "$ROOT_DIR/Scripts/package-update.sh" >/dev/null 2>&1; then
  printf "Production packaging unexpectedly accepted an ad-hoc CI app.\n" >&2
  exit 1
fi

printf "CI verification passed.\n"
