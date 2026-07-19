#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

delta_assert_immutable_build_identity \
  "0.4.0" "10" "same" \
  "0.4.0" "10" "same"
delta_assert_immutable_build_identity \
  "0.4.0" "10" "old" \
  "0.4.0" "11" "new"
delta_assert_immutable_build_identity \
  "0.3.0" "9" "old" \
  "0.4.0" "10" "new"

ERROR_OUTPUT="$(/usr/bin/mktemp -t delta-immutable-build.XXXXXX)"
if (
  delta_assert_immutable_build_identity \
    "0.4.0" "10" "old" \
    "0.4.0" "10" "new"
) 2>"$ERROR_OUTPUT"; then
  /bin/rm -f "$ERROR_OUTPUT"
  printf 'Immutable build identity accepted different signed bytes.\n' >&2
  exit 1
fi
/usr/bin/grep -Fq \
  'advance CURRENT_PROJECT_VERSION so one build identity always names one immutable app' \
  "$ERROR_OUTPUT"
/bin/rm -f "$ERROR_OUTPUT"

printf 'Immutable build identity policy verified.\n'
