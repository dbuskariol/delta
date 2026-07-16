#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

TMP_DIR="$(/usr/bin/mktemp -d -t delta-notary-contract.XXXXXX)"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

VERSION="9.8.7"
BUILD="654"

for artifact in app dmg; do
  submission="$(delta_notarization_submission_path "$TMP_DIR" "$artifact" "$VERSION" "$BUILD")"
  log="$(delta_notarization_log_path "$TMP_DIR" "$artifact" "$VERSION" "$BUILD")"

  [[ "$submission" == "$TMP_DIR/notary-submit-$artifact-$VERSION-$BUILD.json" ]]
  [[ "$log" == "$TMP_DIR/notary-log-$artifact-$VERSION-$BUILD.json" ]]

  printf '{"id":"fixture-%s","status":"Accepted"}\n' "$artifact" >"$submission"
  printf '{"status":"Accepted","issues":[]}\n' >"$log"
  delta_verify_notarization_record "$TMP_DIR" "$artifact" "$VERSION" "$BUILD"

  printf '{"status":"Invalid","issues":[]}\n' >"$log"
  if delta_verify_notarization_record "$TMP_DIR" "$artifact" "$VERSION" "$BUILD"; then
    printf 'Invalid %s notarization log was accepted.\n' "$artifact" >&2
    exit 1
  fi
done

printf 'Notarization artifact contract self-test passed.\n'
