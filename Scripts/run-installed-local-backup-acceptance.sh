#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_INSTALLED_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"

if [[ ! -d "$APP_PATH" ]]; then
  printf "Delta app bundle not found at %s\n" "$APP_PATH" >&2
  exit 1
fi

RESTIC="$APP_PATH/Contents/MacOS/restic"
if [[ ! -x "$RESTIC" ]]; then
  printf "Bundled restic was not executable at %s\n" "$RESTIC" >&2
  exit 1
fi

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-installed-local-backup-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/installed-local-backup-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-installed-local-backup.XXXXXX)"
trap '/bin/rm -rf "$WORK_DIR"' EXIT

REPOSITORY_DIR="$WORK_DIR/destination"
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

/bin/mkdir -p "$REPOSITORY_DIR" "$SOURCE_DIR/Documents" "$SOURCE_DIR/Photos" "$RESTORE_FULL_DIR" "$RESTORE_SELECTED_DIR"
/usr/bin/uuidgen >"$PASSWORD_FILE"
/bin/chmod 600 "$PASSWORD_FILE"

printf "Quarterly restore validation\n" >"$SOURCE_DIR/Documents/report.txt"
printf "image-bytes-%s\n" "$TIMESTAMP" >"$SOURCE_DIR/Photos/image.txt"
printf "root marker\n" >"$SOURCE_DIR/root.txt"

RESTIC_ARGS=(
  "--repo" "$REPOSITORY_DIR"
  "--password-file" "$PASSWORD_FILE"
)

cat >"$OUTPUT" <<EOF
# Delta Installed Local Backup Acceptance

- Generated: $TIMESTAMP UTC
- App: $APP_PATH
- Restic: $RESTIC
- Work Dir: $WORK_DIR

This verifies the installed app bundle's backup engine against a temporary encrypted local destination. Secrets and data live only under the temporary work directory and are removed when the script exits.

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

snapshot_id_at() {
  local file="$1"
  local index="$2"
  /usr/bin/plutil -extract "$index.id" raw -o - "$file"
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
append_step "Initialize Temporary Destination" "$RESTIC" "${RESTIC_ARGS[@]}" init --json
run_to_file "$FIRST_BACKUP_OUTPUT" "$RESTIC" "${RESTIC_ARGS[@]}" backup --json --compression auto --skip-if-unchanged --tag delta --tag installed-local-acceptance "$SOURCE_DIR"
append_file_step "First Backup" "$FIRST_BACKUP_OUTPUT"
extract_summary "$FIRST_BACKUP_OUTPUT" "$FIRST_BACKUP_SUMMARY"
"$RESTIC" "${RESTIC_ARGS[@]}" snapshots --json >"$SNAPSHOTS_FILE"
first_snapshot_count="$(snapshot_count "$SNAPSHOTS_FILE")"
if [[ "$first_snapshot_count" -ne 1 ]]; then
  printf "Expected one restore point after first backup, found %s\n" "$first_snapshot_count" >&2
  exit 1
fi
first_snapshot_id="$(json_field "$FIRST_BACKUP_SUMMARY" snapshot_id)"
if [[ -z "$first_snapshot_id" ]]; then
  printf "Could not read restore point id after first backup.\n" >&2
  exit 1
fi

run_to_file "$SECOND_BACKUP_OUTPUT" "$RESTIC" "${RESTIC_ARGS[@]}" backup --json --compression auto --skip-if-unchanged --tag delta --tag installed-local-acceptance "$SOURCE_DIR"
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
  snapshot_id="$first_snapshot_id"
fi

append_step "List Restore Points" /bin/cat "$SNAPSHOTS_AFTER_SECOND_FILE"
append_step "Restore Full Snapshot" "$RESTIC" "${RESTIC_ARGS[@]}" restore --json "$snapshot_id" --target "$RESTORE_FULL_DIR"
assert_file_contains "$RESTORE_FULL_DIR" "report.txt" "Quarterly restore validation"
assert_file_contains "$RESTORE_FULL_DIR" "image.txt" "image-bytes"

append_step "Restore Selected Folder" "$RESTIC" "${RESTIC_ARGS[@]}" restore --json "$snapshot_id:$SOURCE_DIR/Documents" --target "$RESTORE_SELECTED_DIR"
assert_file_contains "$RESTORE_SELECTED_DIR" "report.txt" "Quarterly restore validation"
if /usr/bin/find "$RESTORE_SELECTED_DIR" -type f -name "image.txt" -print -quit | /usr/bin/grep -q .; then
  printf "Selected folder restore unexpectedly restored image.txt.\n" >&2
  exit 1
fi

append_step "Check Destination" "$RESTIC" "${RESTIC_ARGS[@]}" check --json
append_step "Forget, Prune, And Verify" "$RESTIC" "${RESTIC_ARGS[@]}" forget --keep-last 1 --group-by host,paths,tags --prune --json
append_step "Post-Prune Check" "$RESTIC" "${RESTIC_ARGS[@]}" check --json --read-data-subset 1/100

cat >>"$OUTPUT" <<EOF
## Result

Installed local backup acceptance passed.

- Restore point: $snapshot_id
- Restore point count after first backup: $first_snapshot_count
- Restore point count after no-change backup: $second_snapshot_count
- Second backup files new: $second_files_new
- Second backup files changed: $second_files_changed
- Second backup data blobs: $second_data_blobs
EOF

LATEST_TMP="$OUTPUT_DIR/.installed-local-backup-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed local backup acceptance to %s\n" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed local backup acceptance passed for %s\n" "$APP_PATH"
