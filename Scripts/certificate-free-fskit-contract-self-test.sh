#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

APP_PATH="${1:-$ROOT_DIR/dist/Delta.app}"
SOURCE_EXTENSION="$APP_PATH/Contents/Extensions/DeltaTimeMachineFS.appex"
[[ -d "$SOURCE_EXTENSION" ]] \
  || delta_fail "the certificate-free FSKit contract self-test requires $SOURCE_EXTENSION"

delta_assert_certificate_free_fskit_extension "$APP_PATH"

WORK_DIR="$(/usr/bin/mktemp -d -t delta-ci-fskit-contract.XXXXXX)"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
FIXTURE_APP="$WORK_DIR/Delta.app"
FIXTURE_EXTENSION="$FIXTURE_APP/Contents/Extensions/DeltaTimeMachineFS.appex"

reset_fixture() {
  /bin/rm -rf "$FIXTURE_APP"
  /bin/mkdir -p "$FIXTURE_APP/Contents/Extensions"
  /usr/bin/ditto "$SOURCE_EXTENSION" "$FIXTURE_EXTENSION"
}

expect_rejection() {
  local expected="$1"
  local output status
  set +e
  output="$( ( delta_assert_certificate_free_fskit_extension "$FIXTURE_APP" ) 2>&1 )"
  status=$?
  set -e
  [[ "$status" -ne 0 ]] \
    || delta_fail "the certificate-free FSKit contract accepted an invalid fixture: $expected"
  /usr/bin/grep -Fq "$expected" <<<"$output" \
    || delta_fail "the certificate-free FSKit contract rejected a fixture without the expected reason: $expected"
}

reset_fixture
/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  --entitlements "$ROOT_DIR/Packaging/DeltaTimeMachineFS.entitlements" \
  "$FIXTURE_EXTENSION" >/dev/null
expect_rejection 'unexpectedly carries the restricted FSKit entitlement'

reset_fixture
/usr/bin/touch "$FIXTURE_EXTENSION/Contents/embedded.provisionprofile"
/usr/bin/codesign --force --sign - --timestamp=none "$FIXTURE_EXTENSION" >/dev/null
expect_rejection 'unexpectedly embeds a provisioning profile'

printf 'Certificate-free FSKit contract self-test passed.\n'
