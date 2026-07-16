#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

MODE="${1:-prepare}"
case "$MODE" in
  prepare|finalize) ;;
  *)
    printf 'Usage: Scripts/release.sh [prepare|finalize]\n' >&2
    exit 64
    ;;
esac

if [[ "$MODE" == "finalize" ]]; then
  [[ "${DELTA_ALLOW_DIRTY:-0}" != "1" ]] \
    || delta_fail 'final releases can never be built from a dirty worktree'
  export DELTA_REQUIRE_RELEASE_TAG=1
fi

delta_assert_clean_worktree "$ROOT_DIR"
IFS=$'\t' read -r VERSION BUILD < <(delta_assert_release_metadata "$ROOT_DIR")
export DELTA_EXPECTED_RELEASE_VERSION="$VERSION"
export DELTA_EXPECTED_RELEASE_BUILD="$BUILD"
delta_note "Preparing Delta $VERSION ($BUILD) in $MODE mode"

/bin/rm -rf "$ROOT_DIR/dist"
"$ROOT_DIR/Scripts/build-release.sh"
"$ROOT_DIR/Scripts/verify-release-candidate.sh" "$ROOT_DIR/dist/Delta.app"

if [[ "$MODE" == "prepare" ]]; then
  DELTA_NOTARY_PREPARE_ONLY=1 "$ROOT_DIR/Scripts/notarize-release.sh"
  DELTA_SKIP_BUILD=1 \
    DELTA_ALLOW_UNNOTARIZED_PACKAGE=1 \
    "$ROOT_DIR/Scripts/package-update.sh"
  DELTA_ALLOW_UNNOTARIZED_PACKAGE=1 \
    "$ROOT_DIR/Scripts/generate-appcast.sh"
  DELTA_ALLOW_UNNOTARIZED_PACKAGE=1 \
    "$ROOT_DIR/Scripts/create-release-manifest.sh"
  delta_record_automated_gate_status "$ROOT_DIR" "$ROOT_DIR/dist/Delta.app" "$MODE"
  delta_note 'Release rehearsal passed; no Apple service or publishing state was changed'
  exit 0
fi

"$ROOT_DIR/Scripts/notarize-release.sh"
"$ROOT_DIR/Scripts/create-release-manifest.sh"
delta_record_automated_gate_status "$ROOT_DIR" "$ROOT_DIR/dist/Delta.app" "$MODE"

delta_note "Delta $VERSION ($BUILD) is signed, notarized, stapled, Sparkle-signed, and ready to publish"
