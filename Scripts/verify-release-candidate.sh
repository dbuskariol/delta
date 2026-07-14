#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"
APP="${1:-$ROOT_DIR/dist/Delta.app}"

delta_assert_release_app "$APP" "$DELTA_EXPECTED_TEAM_ID"

cd "$ROOT_DIR"
/usr/bin/swift test
"$ROOT_DIR/Scripts/verify-product-language.sh"
"$ROOT_DIR/Scripts/verify-no-crash-markers.sh"
"$ROOT_DIR/Scripts/verify-notarization-policy.sh"
"$ROOT_DIR/Scripts/verify-ci-workflows.sh"
"$ROOT_DIR/Scripts/verify-manual-acceptance-matrix.sh"
"$ROOT_DIR/Scripts/verify-manual-acceptance-self-test.sh"
"$ROOT_DIR/Scripts/manual-acceptance-status-self-test.sh"
"$ROOT_DIR/Scripts/record-manual-acceptance-result-self-test.sh"
"$ROOT_DIR/Scripts/verify-external-acceptance-evidence-self-test.sh" "$APP"
"$ROOT_DIR/Scripts/verify-tools.sh"
"$ROOT_DIR/Scripts/verify-restic-surface.sh"

DELTA_RESTIC_INTEGRATION=1 \
RESTIC_BINARY="$APP/Contents/MacOS/restic" \
/usr/bin/swift test --filter ResticIntegrationTests

DELTA_VERIFY_INSTALLED_LAUNCH=1 "$ROOT_DIR/Scripts/verify-installed-app.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-keychain-access-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-diagnostics-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-preferences-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-menu-bar-surface-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-scheduled-agent-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-run-control-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-local-backup-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-mounted-volume-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-local-rest-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-local-s3-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-local-sftp-acceptance.sh" "$APP"
"$ROOT_DIR/Scripts/run-installed-rclone-local-acceptance.sh" "$APP"

delta_note 'Signed release-candidate functional and integration verification passed'
