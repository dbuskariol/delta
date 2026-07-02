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

assert_no_runtime_exception_entitlements() {
  local target="$1"
  local entitlements
  entitlements="$(/usr/bin/codesign -d --entitlements :- "$target" 2>/dev/null || true)"
  for key in \
    "com.apple.security.cs.allow-jit" \
    "com.apple.security.cs.allow-unsigned-executable-memory" \
    "com.apple.security.cs.disable-library-validation"
  do
    if /usr/bin/grep -q "<key>$key</key>" <<<"$entitlements"; then
      printf "%s contains unnecessary hardened-runtime exception entitlement: %s\n" "$target" "$key" >&2
      exit 1
    fi
  done
}

assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaAgent"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaSecretBridge"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/restic"
assert_no_runtime_exception_entitlements "$ROOT_DIR/dist/Delta.app/Contents/MacOS/rclone"

if ! /usr/bin/otool -l "$ROOT_DIR/dist/Delta.app/Contents/MacOS/Delta" | /usr/bin/grep -q "@executable_path/../Frameworks"; then
  printf "Delta.app is missing the Frameworks runtime search path.\n" >&2
  exit 1
fi
if [[ ! -f "$ROOT_DIR/dist/Delta.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]]; then
  printf "Delta.app is missing the embedded Sparkle framework binary.\n" >&2
  exit 1
fi
LAUNCH_AGENT_PLIST="$ROOT_DIR/dist/Delta.app/Contents/Library/LaunchAgents/com.delta.backup.agent.plist"
if [[ ! -f "$LAUNCH_AGENT_PLIST" ]]; then
  printf "Delta.app is missing the bundled LaunchAgent plist.\n" >&2
  exit 1
fi
/usr/bin/plutil -lint "$LAUNCH_AGENT_PLIST" >/dev/null
AGENT_BUNDLE_PROGRAM="$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$LAUNCH_AGENT_PLIST")"
if [[ ! -x "$ROOT_DIR/dist/Delta.app/$AGENT_BUNDLE_PROGRAM" ]]; then
  printf "LaunchAgent BundleProgram is not executable: %s\n" "$AGENT_BUNDLE_PROGRAM" >&2
  exit 1
fi
AGENT_RUN_AT_LOAD="$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$LAUNCH_AGENT_PLIST")"
AGENT_START_INTERVAL="$(/usr/libexec/PlistBuddy -c 'Print :StartInterval' "$LAUNCH_AGENT_PLIST")"
if [[ "$AGENT_RUN_AT_LOAD" != "true" || "$AGENT_START_INTERVAL" -lt 60 ]]; then
  printf "LaunchAgent schedule is invalid. RunAtLoad=%s StartInterval=%s\n" "$AGENT_RUN_AT_LOAD" "$AGENT_START_INTERVAL" >&2
  exit 1
fi
/usr/bin/codesign --verify --strict --verbose=2 "$ROOT_DIR/dist/Delta.app/$AGENT_BUNDLE_PROGRAM"
/usr/bin/codesign --verify --strict --verbose=2 "$ROOT_DIR/dist/Delta.app/Contents/MacOS/DeltaSecretBridge"

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

"$ROOT_DIR/Scripts/package-update.sh"
"$ROOT_DIR/Scripts/generate-appcast.sh"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT_DIR/dist/Delta.app/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT_DIR/dist/Delta.app/Contents/Info.plist")"
ARCHIVE_NAME="Delta-$SHORT_VERSION-$BUILD_VERSION.zip"
APPCAST="$ROOT_DIR/dist/updates/appcast.xml"
if [[ ! -f "$ROOT_DIR/dist/updates/$ARCHIVE_NAME" ]]; then
  printf "Sparkle update archive %s was not generated.\n" "$ARCHIVE_NAME" >&2
  exit 1
fi
if ! /usr/bin/grep -q "<sparkle:shortVersionString>$SHORT_VERSION</sparkle:shortVersionString>" "$APPCAST"; then
  printf "Sparkle appcast does not contain short version %s.\n" "$SHORT_VERSION" >&2
  exit 1
fi
if ! /usr/bin/grep -q "<sparkle:version>$BUILD_VERSION</sparkle:version>" "$APPCAST"; then
  printf "Sparkle appcast does not contain build version %s.\n" "$BUILD_VERSION" >&2
  exit 1
fi
if ! /usr/bin/grep -q "$ARCHIVE_NAME" "$APPCAST"; then
  printf "Sparkle appcast does not reference %s.\n" "$ARCHIVE_NAME" >&2
  exit 1
fi

printf "Release verification passed for %s\n" "$ROOT_DIR/dist/Delta.app"
