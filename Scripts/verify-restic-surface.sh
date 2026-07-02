#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESTIC="${RESTIC_BINARY:-$ROOT_DIR/Resources/Tools/bin/restic}"

if [[ ! -x "$RESTIC" ]]; then
  printf "restic is not executable at %s\n" "$RESTIC" >&2
  exit 1
fi

HELP_DIR="$(/usr/bin/mktemp -d -t delta-restic-help.XXXXXX)"
trap 'rm -rf "$HELP_DIR"' EXIT
RESTIC_OPTIONS_OUTPUT="$("$RESTIC" options)"

help_file() {
  local command="$1"
  local path="$HELP_DIR/$command.txt"
  if [[ ! -f "$path" ]]; then
    "$RESTIC" help "$command" >"$path"
  fi
  printf "%s" "$path"
}

assert_command() {
  local command="$1"
  if ! "$RESTIC" help "$command" >/dev/null 2>&1; then
    printf "Bundled restic does not expose required command: %s\n" "$command" >&2
    exit 1
  fi
}

assert_help_contains() {
  local command="$1"
  local pattern="$2"
  local path
  path="$(help_file "$command")"
  if ! /usr/bin/grep -Eq -- "$pattern" "$path"; then
    printf "Bundled restic help for '%s' does not contain required pattern: %s\n" "$command" "$pattern" >&2
    exit 1
  fi
}

assert_options_contains() {
  local pattern="$1"
  if ! /usr/bin/grep -Eq -- "$pattern" <<<"$RESTIC_OPTIONS_OUTPUT"; then
    printf "Bundled restic options do not contain required pattern: %s\n" "$pattern" >&2
    exit 1
  fi
}

for command in init backup snapshots ls restore forget check; do
  assert_command "$command"
  assert_help_contains "$command" "--json"
  assert_help_contains "$command" "--repo repository"
  assert_help_contains "$command" "--password-command command"
  assert_help_contains "$command" "--cleanup-cache"
  assert_help_contains "$command" "--option key=value"
done

assert_help_contains backup "--compression mode"
assert_help_contains backup "--limit-upload rate"
assert_help_contains backup "--limit-download rate"
assert_help_contains backup "--skip-if-unchanged"
assert_help_contains backup "--one-file-system"
assert_help_contains backup "--exclude pattern"
assert_help_contains backup "--tag tags"

assert_help_contains ls "--sort mode"

assert_help_contains restore "--overwrite behavior"
assert_help_contains restore "--target string"
assert_help_contains restore "--include pattern"
assert_help_contains restore "--dry-run"
assert_help_contains restore "--verify"
assert_help_contains restore "--verbose"

assert_help_contains forget "--keep-hourly n"
assert_help_contains forget "--keep-daily n"
assert_help_contains forget "--keep-weekly n"
assert_help_contains forget "--keep-monthly n"
assert_help_contains forget "--keep-yearly n"
assert_help_contains forget "--group-by group"
assert_help_contains forget "--prune"

assert_help_contains check "--read-data-subset subset"

assert_options_contains "sftp\\.args"
assert_options_contains "sftp\\.command"
assert_options_contains "sftp\\.connections"
assert_options_contains "rclone\\.program"
assert_options_contains "s3\\.region"

printf "Bundled restic command surface verified: %s\n" "$("$RESTIC" version)"
