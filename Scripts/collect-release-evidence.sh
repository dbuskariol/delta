#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_EVIDENCE_APP:-$ROOT_DIR/dist/Delta.app}}"
OUTPUT_DIR="${DELTA_EVIDENCE_DIR:-$ROOT_DIR/dist/release-evidence}"

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-release-evidence-$TIMESTAMP.md"
INFO_PLIST="$APP_PATH/Contents/Info.plist"

plist_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || printf "Unknown"
}

append_command() {
  local title="$1"
  shift
  {
    printf "### %s\n\n" "$title"
    printf '```text\n'
    "$@" 2>&1 || printf "Command exited with status %s\n" "$?"
    printf '```\n\n'
  } >>"$OUTPUT"
}

SHORT_VERSION="$(plist_value CFBundleShortVersionString)"
BUILD_VERSION="$(plist_value CFBundleVersion)"
BUNDLE_ID="$(plist_value CFBundleIdentifier)"
GIT_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")"

cat >"$OUTPUT" <<EOF
# Delta Release Evidence

- Generated: $TIMESTAMP UTC
- App: $APP_PATH
- Bundle ID: $BUNDLE_ID
- Version: $SHORT_VERSION
- Build: $BUILD_VERSION
- Git Commit: $GIT_COMMIT
- Host macOS: $(/usr/bin/sw_vers -productVersion) ($(/usr/bin/sw_vers -buildVersion))

## Automated Evidence

EOF

append_command "Code Signature Verification" /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_PATH"
append_command "Code Signature Details" /usr/bin/codesign -dv "$APP_PATH"
append_command "Gatekeeper Assessment" /usr/sbin/spctl --assess --type execute --verbose=4 "$APP_PATH"
append_command "Stapled Notarization Ticket" /usr/bin/stapler validate "$APP_PATH"
append_command "Background Scheduling Helper Status" "$APP_PATH/Contents/MacOS/DeltaAgent" --status
append_command "Background Scheduling Helper Dry Run" "$APP_PATH/Contents/MacOS/DeltaAgent" --dry-run
append_command "Bundled Backup Engine" "$APP_PATH/Contents/MacOS/restic" version
append_command "Bundled Cloud Helper" "$APP_PATH/Contents/MacOS/rclone" version
append_command "Secret Bridge Fail-Closed Check" /bin/sh -c "'$APP_PATH/Contents/MacOS/DeltaSecretBridge' 2>&1; test \$? -eq 64"

if [[ -d "$ROOT_DIR/dist/updates" ]]; then
  append_command "Sparkle Update Artifacts" /bin/sh -c "ls -la '$ROOT_DIR/dist/updates' && test -f '$ROOT_DIR/dist/updates/appcast.xml' && grep -E 'sparkle:(version|shortVersionString)|sparkle:edSignature' '$ROOT_DIR/dist/updates/appcast.xml'"
fi

cat >>"$OUTPUT" <<'EOF'
## Manual macOS Acceptance Evidence

Record tester, date, macOS build, signing identity, and notes beside each item before external beta distribution.

| Area | Result | Evidence / Notes |
| --- | --- | --- |
| Install identity and privacy stability | Not run | |
| Settings surface | Not run | |
| Full Disk Access | Not run | |
| Background Scheduling and Login Items approval | Not run | |
| Keychain background access without prompts | Not run | |
| Local or external drive destination | Not run | |
| Mounted SMB or NFS destination | Not run | |
| SFTP destination | Not run | |
| S3-compatible destination | Not run | |
| Remote first-backup preparation | Not run | |
| Restore wizard full and selected restore | Not run | |
| Restore defaults | Not run | |
| New backup defaults | Not run | |
| Browse restore points | Not run | |
| Pause, resume, and cancel | Not run | |
| Streaming and saved logs | Not run | |
| Menu bar status item and persistent popover | Not run | |
| Notifications | Not run | |
| Sparkle update install | Not run | |
| Diagnostics export redaction | Not run | |
| Developer ID notarization | Not run | |

## Release Decision

- Automated gate passed: Not recorded here
- Manual matrix passed: No
- Developer ID notarization complete: No
- Ready for external distribution: No
EOF

printf "Wrote release evidence to %s\n" "$OUTPUT"
