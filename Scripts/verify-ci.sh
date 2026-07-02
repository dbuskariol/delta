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
"$ROOT_DIR/Scripts/verify-ci-workflows.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-local-s3-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-local-sftp-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-mounted-volume-acceptance.sh"
/bin/bash -n "$ROOT_DIR/Scripts/run-installed-rclone-local-acceptance.sh"
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

DELTA_SKIP_BUILD=1 "$ROOT_DIR/Scripts/package-update.sh"
"$ROOT_DIR/Scripts/generate-appcast.sh"
DELTA_ALLOW_ADHOC_UPDATE_VERIFICATION=1 \
  "$ROOT_DIR/Scripts/verify-sparkle-update-artifacts.sh" "$ROOT_DIR/dist/Delta.app" "$ROOT_DIR/dist/updates"

printf "CI verification passed.\n"
