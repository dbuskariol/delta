#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/Scripts/notarize-release.sh"
LIBRARY="$ROOT_DIR/Scripts/lib/delta-release.sh"

if /usr/bin/grep -Eq 'DELTA_NOTARY_(APPLE_ID|TEAM_ID|PASSWORD)' "$SCRIPT" "$LIBRARY"; then
  printf "notarize-release.sh must not accept raw Apple ID notarization credentials from environment variables.\n" >&2
  exit 1
fi

if /usr/bin/grep -Eq 'notarytool submit .*--(apple-id|team-id|password)' "$SCRIPT" "$LIBRARY"; then
  printf "notarize-release.sh must submit with a stored notarytool keychain profile, not inline credentials.\n" >&2
  exit 1
fi

if ! /usr/bin/grep -q -- '--keychain-profile' "$LIBRARY"; then
  printf "notarize-release.sh must use notarytool keychain profiles for submissions.\n" >&2
  exit 1
fi

printf "Notarization credential policy verified.\n"
