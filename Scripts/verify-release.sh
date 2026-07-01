#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

/usr/bin/swift test

"$ROOT_DIR/Scripts/bootstrap-tools.sh"
"$ROOT_DIR/Scripts/verify-tools.sh"

DELTA_RESTIC_INTEGRATION=1 \
RESTIC_BINARY="$ROOT_DIR/Resources/Tools/bin/restic" \
/usr/bin/swift test --filter ResticIntegrationTests

"$ROOT_DIR/Scripts/build-app.sh"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$ROOT_DIR/dist/Delta.app"

if ! /usr/bin/otool -l "$ROOT_DIR/dist/Delta.app/Contents/MacOS/Delta" | /usr/bin/grep -q "@executable_path/../Frameworks"; then
  printf "Delta.app is missing the Frameworks runtime search path.\n" >&2
  exit 1
fi
if [[ ! -f "$ROOT_DIR/dist/Delta.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]; then
  printf "Delta.app is missing the embedded Sparkle framework binary.\n" >&2
  exit 1
fi

LAUNCH_LOG="$(/usr/bin/mktemp -t delta-launch-smoke.XXXXXX)"
"$ROOT_DIR/dist/Delta.app/Contents/MacOS/Delta" >"$LAUNCH_LOG" 2>&1 &
DELTA_PID=$!
/bin/sleep 2
if ! /bin/kill -0 "$DELTA_PID" >/dev/null 2>&1; then
  /bin/cat "$LAUNCH_LOG" >&2
  /bin/rm -f "$LAUNCH_LOG"
  exit 1
fi
/bin/kill "$DELTA_PID" >/dev/null 2>&1 || true
wait "$DELTA_PID" >/dev/null 2>&1 || true
/bin/rm -f "$LAUNCH_LOG"

"$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaAgent" --status
"$ROOT_DIR/dist/Delta.app/Contents/MacOS/restic" version
"$ROOT_DIR/dist/Delta.app/Contents/MacOS/rclone" version | /usr/bin/head -n 1

printf "Release verification passed for %s\n" "$ROOT_DIR/dist/Delta.app"
