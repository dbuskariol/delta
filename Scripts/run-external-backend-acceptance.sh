#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="${1:-}"
APP_PATH="${2:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_EXTERNAL_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"

usage() {
  cat >&2 <<'EOF'
usage: Scripts/run-external-backend-acceptance.sh <mounted|sftp|s3> [Delta.app]

Environment:
  mounted:
    DELTA_ACCEPTANCE_MOUNTED_PATH=/Volumes/YourMountedShare

  sftp:
    DELTA_ACCEPTANCE_SFTP_REPOSITORY=sftp:user@example.com:/absolute/delta-acceptance-path
    DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY=/path/to/key   optional; ssh-agent/config also works
    DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY=...         optional; must fail before success

  s3:
    DELTA_ACCEPTANCE_S3_REPOSITORY=s3:https://endpoint/bucket/delta-acceptance-path
    AWS_ACCESS_KEY_ID=...
    AWS_SECRET_ACCESS_KEY=...
    AWS_SESSION_TOKEN=...                            optional
    AWS_DEFAULT_REGION=...                           optional

Remote repository URLs must include "delta-acceptance" unless DELTA_ACCEPTANCE_ALLOW_EXISTING_REMOTE=1 is set.
EOF
}

fail() {
  printf "%s\n" "$1" >&2
  exit "${2:-1}"
}

probe_writable_directory() {
  local directory="$1"
  local probe_file="$directory/.delta-write-probe.$$.$RANDOM"
  if ! /usr/bin/printf "delta\n" >"$probe_file" 2>/dev/null; then
    /bin/rm -f "$probe_file" 2>/dev/null || true
    return 1
  fi
  /bin/rm -f "$probe_file" 2>/dev/null
}

case "$KIND" in
  mounted|sftp|s3)
    ;;
  "")
    usage
    exit 64
    ;;
  *)
    usage
    fail "Unsupported external backend acceptance kind: $KIND" 64
    ;;
esac

if [[ ! -d "$APP_PATH" ]]; then
  fail "Delta app bundle not found at $APP_PATH"
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
plist_value() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" 2>/dev/null || printf "Unknown"
}

RESTIC="$APP_PATH/Contents/MacOS/restic"
if [[ ! -x "$RESTIC" ]]; then
  fail "Bundled restic was not executable at $RESTIC"
fi

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-external-$KIND-acceptance-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/external-$KIND-acceptance-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t "delta-external-$KIND.XXXXXX")"
CLEANUP_PATHS=("$WORK_DIR")

cleanup() {
  local path
  for path in "${CLEANUP_PATHS[@]}"; do
    if [[ -n "$path" && -e "$path" ]]; then
      /bin/rm -rf "$path"
    fi
  done
}
trap cleanup EXIT

SOURCE_DIR="$WORK_DIR/source"
RESTORE_FULL_DIR="$WORK_DIR/restore-full"
RESTORE_SELECTED_DIR="$WORK_DIR/restore-selected"
PASSWORD_FILE="$WORK_DIR/password"
SNAPSHOTS_FILE="$WORK_DIR/snapshots.json"
SNAPSHOTS_AFTER_SECOND_FILE="$WORK_DIR/snapshots-after-second.json"
FIRST_BACKUP_OUTPUT="$WORK_DIR/first-backup.jsonl"
SECOND_BACKUP_OUTPUT="$WORK_DIR/second-backup.jsonl"
FIRST_BACKUP_SUMMARY="$WORK_DIR/first-backup-summary.json"
SECOND_BACKUP_SUMMARY="$WORK_DIR/second-backup-summary.json"

/bin/mkdir -p "$SOURCE_DIR/Documents" "$SOURCE_DIR/Photos" "$RESTORE_FULL_DIR" "$RESTORE_SELECTED_DIR"
/usr/bin/uuidgen >"$PASSWORD_FILE"
/bin/chmod 600 "$PASSWORD_FILE"

printf "External backend acceptance report\n" >"$SOURCE_DIR/Documents/report.txt"
printf "image-bytes-%s\n" "$TIMESTAMP" >"$SOURCE_DIR/Photos/image.txt"
printf "root marker\n" >"$SOURCE_DIR/root.txt"

repository_url=""
declare -a BACKEND_OPTIONS=()
configured_bad_probe="Not configured"
missing_credential_probe="Not configured"

require_acceptance_remote() {
  local url="$1"
  if [[ "${DELTA_ACCEPTANCE_ALLOW_EXISTING_REMOTE:-0}" == "1" ]]; then
    return
  fi
  case "$url" in
    *delta-acceptance*|*DeltaAcceptance*|*delta_acceptance*)
      ;;
    *)
      fail "Remote acceptance repository URL must include delta-acceptance, or set DELTA_ACCEPTANCE_ALLOW_EXISTING_REMOTE=1 after verifying the target is safe."
      ;;
  esac
}

case "$KIND" in
  mounted)
    mounted_path="${DELTA_ACCEPTANCE_MOUNTED_PATH:-}"
    [[ -n "$mounted_path" ]] || fail "DELTA_ACCEPTANCE_MOUNTED_PATH is required for mounted acceptance." 64
    mounted_path="$(cd "$mounted_path" 2>/dev/null && /bin/pwd -P || true)"
    [[ -n "$mounted_path" && -d "$mounted_path" ]] || fail "Mounted acceptance path is not a readable directory."
    case "$mounted_path" in
      /Volumes/*)
        ;;
      *)
        fail "Mounted acceptance path must live under /Volumes to prove SMB/NFS/external-drive behavior."
        ;;
    esac
    probe_writable_directory "$mounted_path" || fail "Mounted acceptance path did not pass a write/delete probe: $mounted_path"
    repository_dir="$(/usr/bin/mktemp -d "$mounted_path/DeltaExternalAcceptance.XXXXXX")"
    CLEANUP_PATHS+=("$repository_dir")
    repository_url="$repository_dir"
    ;;
  sftp)
    repository_url="${DELTA_ACCEPTANCE_SFTP_REPOSITORY:-}"
    [[ -n "$repository_url" ]] || fail "DELTA_ACCEPTANCE_SFTP_REPOSITORY is required for SFTP acceptance." 64
    require_acceptance_remote "$repository_url"
    if [[ -n "${DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY:-}" ]]; then
      [[ -r "$DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY" ]] || fail "SFTP private key is not readable: $DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY"
      BACKEND_OPTIONS+=("-o" "sftp.command=ssh -i $DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY -o BatchMode=yes -o IdentitiesOnly=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=2")
    fi
    if [[ -n "${DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY:-}" ]]; then
      require_acceptance_remote "$DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY"
    fi
    ;;
  s3)
    repository_url="${DELTA_ACCEPTANCE_S3_REPOSITORY:-}"
    [[ -n "$repository_url" ]] || fail "DELTA_ACCEPTANCE_S3_REPOSITORY is required for S3 acceptance." 64
    require_acceptance_remote "$repository_url"
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || fail "AWS_ACCESS_KEY_ID is required for S3 acceptance." 64
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || fail "AWS_SECRET_ACCESS_KEY is required for S3 acceptance." 64
    ;;
esac

RESTIC_ARGS=(
  "--repo" "$repository_url"
  "--password-file" "$PASSWORD_FILE"
)
if [[ "${#BACKEND_OPTIONS[@]}" -gt 0 ]]; then
  RESTIC_ARGS+=("${BACKEND_OPTIONS[@]}")
fi

cat >"$OUTPUT" <<EOF
# Delta External Backend Acceptance

- Generated: $TIMESTAMP UTC
- Kind: $KIND
- App: $APP_PATH
- Bundle ID: $(plist_value CFBundleIdentifier)
- Version: $(plist_value CFBundleShortVersionString)
- Build: $(plist_value CFBundleVersion)
- Git Commit: $(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")
- Restic: $RESTIC
- Repository: $repository_url

This verifies the installed app bundle's backup engine against a configured external destination. The script uses a unique password and tagged test data. Remote repository URLs must be dedicated acceptance locations unless explicitly overridden.

EOF

append_step() {
  local title="$1"
  shift
  {
    printf "## %s\n\n" "$title"
    printf '```text\n'
    "$@" 2>&1
    printf '```\n\n'
  } >>"$OUTPUT"
}

append_file_step() {
  local title="$1"
  local file="$2"
  {
    printf "## %s\n\n" "$title"
    printf '```text\n'
    /bin/cat "$file"
    printf '```\n\n'
  } >>"$OUTPUT"
}

run_to_file() {
  local file="$1"
  shift
  "$@" >"$file" 2>&1
}

run_expect_failure() {
  local title="$1"
  shift
  local file="$WORK_DIR/$(printf "%s" "$title" | /usr/bin/tr '[:upper:] ' '[:lower:]-').out"
  set +e
  "$@" >"$file" 2>&1
  local status=$?
  set -e
  append_file_step "$title" "$file"
  if [[ "$status" -eq 0 ]]; then
    printf "Expected failure for %s, but command succeeded.\n" "$title" >&2
    exit 1
  fi
}

extract_summary() {
  local input="$1"
  local output="$2"
  /usr/bin/awk '/"message_type":"summary"/ { line = $0 } END { if (line != "") { print line } else { exit 1 } }' "$input" >"$output"
}

json_field() {
  local file="$1"
  local key="$2"
  /usr/bin/plutil -extract "$key" raw -o - "$file"
}

snapshot_count() {
  local file="$1"
  local count=0
  while /usr/bin/plutil -extract "$count.id" raw -o - "$file" >/dev/null 2>&1; do
    count=$((count + 1))
  done
  printf "%s\n" "$count"
}

assert_file_contains() {
  local directory="$1"
  local filename="$2"
  local expected="$3"
  local found
  found="$(/usr/bin/find "$directory" -type f -name "$filename" -print -quit)"
  if [[ -z "$found" ]]; then
    printf "Expected restored file named %s under %s\n" "$filename" "$directory" >&2
    exit 1
  fi
  if ! /usr/bin/grep -q "$expected" "$found"; then
    printf "Restored file %s did not contain expected text.\n" "$found" >&2
    exit 1
  fi
}

append_step "Bundled Restic Version" "$RESTIC" version

case "$KIND" in
  sftp)
    if [[ -n "${DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY:-}" ]]; then
      bad_args=("--repo" "$DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY" "--password-file" "$PASSWORD_FILE")
      if [[ "${#BACKEND_OPTIONS[@]}" -gt 0 ]]; then
        bad_args+=("${BACKEND_OPTIONS[@]}")
      fi
      run_expect_failure "Wrong SFTP Credential Or Target Failure" "$RESTIC" "${bad_args[@]}" snapshots --json
      configured_bad_probe="Passed"
    fi
    ;;
  s3)
    run_expect_failure "Missing S3 Credential Failure" /usr/bin/env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN "$RESTIC" "${RESTIC_ARGS[@]}" snapshots --json
    missing_credential_probe="Passed"
    ;;
esac

run_expect_failure "Unprepared Destination Probe" "$RESTIC" "${RESTIC_ARGS[@]}" snapshots --json
append_step "Prepare Destination" "$RESTIC" "${RESTIC_ARGS[@]}" init --json
append_step "Prepared Destination Reuse Probe" "$RESTIC" "${RESTIC_ARGS[@]}" snapshots --json

run_to_file "$FIRST_BACKUP_OUTPUT" "$RESTIC" "${RESTIC_ARGS[@]}" backup --json --compression auto --skip-if-unchanged --tag delta --tag external-acceptance --tag "$KIND" "$SOURCE_DIR"
append_file_step "First Backup" "$FIRST_BACKUP_OUTPUT"
extract_summary "$FIRST_BACKUP_OUTPUT" "$FIRST_BACKUP_SUMMARY"
"$RESTIC" "${RESTIC_ARGS[@]}" snapshots --json >"$SNAPSHOTS_FILE"
first_snapshot_count="$(snapshot_count "$SNAPSHOTS_FILE")"
if [[ "$first_snapshot_count" -lt 1 ]]; then
  printf "Expected at least one restore point after first backup, found %s\n" "$first_snapshot_count" >&2
  exit 1
fi

run_to_file "$SECOND_BACKUP_OUTPUT" "$RESTIC" "${RESTIC_ARGS[@]}" backup --json --compression auto --skip-if-unchanged --tag delta --tag external-acceptance --tag "$KIND" "$SOURCE_DIR"
append_file_step "No-Change Incremental Backup" "$SECOND_BACKUP_OUTPUT"
extract_summary "$SECOND_BACKUP_OUTPUT" "$SECOND_BACKUP_SUMMARY"
"$RESTIC" "${RESTIC_ARGS[@]}" snapshots --json >"$SNAPSHOTS_AFTER_SECOND_FILE"
second_snapshot_count="$(snapshot_count "$SNAPSHOTS_AFTER_SECOND_FILE")"
if [[ "$second_snapshot_count" -lt "$first_snapshot_count" || "$second_snapshot_count" -gt $((first_snapshot_count + 1)) ]]; then
  printf "Expected no-change backup to keep or add one restore point after %s restore point(s), found %s\n" "$first_snapshot_count" "$second_snapshot_count" >&2
  exit 1
fi
second_files_new="$(json_field "$SECOND_BACKUP_SUMMARY" files_new)"
second_files_changed="$(json_field "$SECOND_BACKUP_SUMMARY" files_changed)"
second_data_blobs="$(json_field "$SECOND_BACKUP_SUMMARY" data_blobs)"
if [[ "$second_files_new" != "0" || "$second_files_changed" != "0" || "$second_data_blobs" != "0" ]]; then
  printf "Expected no new or changed file data on second backup; files_new=%s files_changed=%s data_blobs=%s\n" "$second_files_new" "$second_files_changed" "$second_data_blobs" >&2
  exit 1
fi
snapshot_id="$(json_field "$SECOND_BACKUP_SUMMARY" snapshot_id 2>/dev/null || true)"
if [[ -z "$snapshot_id" ]]; then
  snapshot_id="$(json_field "$FIRST_BACKUP_SUMMARY" snapshot_id)"
fi

append_step "List Restore Points After No-Change Backup" /bin/cat "$SNAPSHOTS_AFTER_SECOND_FILE"
append_step "Restore Full Snapshot" "$RESTIC" "${RESTIC_ARGS[@]}" restore --json "$snapshot_id" --target "$RESTORE_FULL_DIR"
assert_file_contains "$RESTORE_FULL_DIR" "report.txt" "External backend acceptance"
assert_file_contains "$RESTORE_FULL_DIR" "image.txt" "image-bytes"

append_step "Restore Selected Folder" "$RESTIC" "${RESTIC_ARGS[@]}" restore --json "$snapshot_id:$SOURCE_DIR/Documents" --target "$RESTORE_SELECTED_DIR"
assert_file_contains "$RESTORE_SELECTED_DIR" "report.txt" "External backend acceptance"
if /usr/bin/find "$RESTORE_SELECTED_DIR" -type f -name "image.txt" -print -quit | /usr/bin/grep -q .; then
  printf "Selected folder restore unexpectedly restored image.txt.\n" >&2
  exit 1
fi

append_step "Check Destination" "$RESTIC" "${RESTIC_ARGS[@]}" check --json
append_step "Forget, Prune, And Verify" "$RESTIC" "${RESTIC_ARGS[@]}" forget --keep-last 1 --group-by host,paths,tags --prune --json
append_step "Post-Prune Check" "$RESTIC" "${RESTIC_ARGS[@]}" check --json --read-data-subset 1/100

cat >>"$OUTPUT" <<EOF
## Result

External $KIND acceptance passed.

- Restore point: $snapshot_id
- Restore point count after first backup: $first_snapshot_count
- Restore point count after no-change backup: $second_snapshot_count
- Missing credential probe: $missing_credential_probe
- Wrong SFTP credential or target probe: $configured_bad_probe
- Second backup files new: $second_files_new
- Second backup files changed: $second_files_changed
- Second backup data blobs: $second_data_blobs
EOF

LATEST_TMP="$OUTPUT_DIR/.external-$KIND-acceptance-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote external %s acceptance to %s\n" "$KIND" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "External %s acceptance passed for %s\n" "$KIND" "$APP_PATH"
