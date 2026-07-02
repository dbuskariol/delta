#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=Scripts/manual-acceptance-items.sh
source "$ROOT_DIR/Scripts/manual-acceptance-items.sh"

APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_ACCEPTANCE_DIR:-$ROOT_DIR/dist/manual-acceptance}"
TESTER="${DELTA_ACCEPTANCE_TESTER:-$(/usr/bin/id -F 2>/dev/null || /usr/bin/whoami)}"
NOTES="${DELTA_ACCEPTANCE_NOTES:-}"

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"

plist_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || printf "Unknown"
}

SIGNING_IDENTITY="$(/usr/bin/codesign -dvv "$APP_PATH" 2>&1 | /usr/bin/awk -F= '/^Authority=/ && identity == "" { identity = $2 } END { print identity }')"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="Unknown"
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-manual-acceptance-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/latest.md"

cat >"$OUTPUT" <<EOF
# Delta Manual Acceptance Report

- Generated: $TIMESTAMP UTC
- Tester: $TESTER
- App: $APP_PATH
- Bundle ID: $(plist_value CFBundleIdentifier)
- Version: $(plist_value CFBundleShortVersionString)
- Build: $(plist_value CFBundleVersion)
- Git Commit: $(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")
- Host macOS: $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))
- Signing Identity: $SIGNING_IDENTITY
- Notes: $NOTES

## Result Values

Use exactly one of these values in the Result column:

- Passed
- Failed
- Blocked
- Not run

## Results

| ID | Area | Result | Evidence / Notes | Required Evidence |
| --- | --- | --- | --- | --- |
EOF

while IFS=$'\t' read -r id area required_evidence; do
  printf '| %s | %s | Not run |  | %s |\n' "$id" "$area" "$required_evidence" >>"$OUTPUT"
done < <(manual_acceptance_items)

cat >>"$OUTPUT" <<'EOF'

## Release Rule

`Scripts/verify-manual-acceptance.sh` passes only when every required row is present and every Result is `Passed`.
EOF

/bin/ln -sfn "$(basename "$OUTPUT")" "$LATEST"
printf "Wrote manual acceptance report to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
