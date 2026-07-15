#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

/usr/bin/swift test

"$ROOT_DIR/Scripts/verify-product-language.sh"
"$ROOT_DIR/Scripts/verify-no-crash-markers.sh"
"$ROOT_DIR/Scripts/verify-notarization-policy.sh"
"$ROOT_DIR/Scripts/verify-manual-acceptance-matrix.sh"
"$ROOT_DIR/Scripts/verify-manual-acceptance-self-test.sh"
"$ROOT_DIR/Scripts/manual-acceptance-status-self-test.sh"
"$ROOT_DIR/Scripts/record-manual-acceptance-result-self-test.sh"
"$ROOT_DIR/Scripts/verify-ci-workflows.sh"
/bin/bash -n "$ROOT_DIR/Scripts/manual-acceptance-status.sh"
/bin/bash -n "$ROOT_DIR/Scripts/manual-acceptance-status-self-test.sh"
/bin/bash -n "$ROOT_DIR/Scripts/record-manual-acceptance-result.sh"
/bin/bash -n "$ROOT_DIR/Scripts/record-manual-acceptance-result-self-test.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-local-s3-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-local-sftp-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-local-rest-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-menu-bar-surface-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-mounted-volume-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-rclone-local-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/preflight-external-backend-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/verify-external-acceptance-evidence.sh"
/bin/bash -n "$ROOT_DIR/Scripts/verify-external-acceptance-evidence-self-test.sh"
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
"$ROOT_DIR/Scripts/verify-external-acceptance-evidence-self-test.sh" "$ROOT_DIR/dist/Delta.app"

INFO="$ROOT_DIR/dist/Delta.app/Contents/Info.plist"
SOURCE_INFO="$ROOT_DIR/Packaging/Delta.app.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SOURCE_INFO")" == '$(MARKETING_VERSION)' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SOURCE_INFO")" == '$(CURRENT_PROJECT_VERSION)' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO")" == "com.delta.backup" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")" == "0.2.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" =~ ^[1-9][0-9]*$ ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")" == "26.0" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO")" == "true" ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO")" == "true" ]]
[[ -f "$ROOT_DIR/dist/Delta.app/Contents/Resources/PrivacyInfo.xcprivacy" ]]
for executable in Delta DeltaAgent DeltaSecretBridge restic rclone; do
  [[ -x "$ROOT_DIR/dist/Delta.app/Contents/MacOS/$executable" ]]
done
[[ -x "$ROOT_DIR/dist/Delta.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]

# Shipping packagers reject this ad-hoc app; CI verifies that the boundary is
# fail-closed rather than weakening release validation for convenience.
if DELTA_SKIP_BUILD=1 "$ROOT_DIR/Scripts/package-update.sh" >/dev/null 2>&1; then
  printf "Production packaging unexpectedly accepted an ad-hoc CI app.\n" >&2
  exit 1
fi

printf "CI verification passed.\n"
