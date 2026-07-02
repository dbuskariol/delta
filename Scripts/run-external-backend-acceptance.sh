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

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
if [[ ! -x "$DELTA_EXECUTABLE" ]]; then
  fail "Delta executable is missing or not executable: $DELTA_EXECUTABLE"
fi

RESTIC="$APP_PATH/Contents/MacOS/restic"
if [[ ! -x "$RESTIC" ]]; then
  fail "Bundled restic was not executable at $RESTIC"
fi

/bin/mkdir -p "$OUTPUT_DIR"
TIMESTAMP="$(/bin/date -u +%Y%m%dT%H%M%SZ)"
OUTPUT="$OUTPUT_DIR/Delta-external-$KIND-acceptance-$TIMESTAMP.md"
LATEST="$OUTPUT_DIR/external-$KIND-acceptance-latest.md"
WORK_DIR="$(/usr/bin/mktemp -d -t "delta-external-$KIND.XXXXXX")"
STDOUT_FILE="$WORK_DIR/external-lifecycle.stdout"
STDERR_FILE="$WORK_DIR/external-lifecycle.stderr"
SUPPORT_DIR="$WORK_DIR/support"
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

declare -a COMMAND_ENV=(
  "DELTA_ENABLE_EXTERNAL_LIFECYCLE_ACCEPTANCE=1"
  "DELTA_APP_SUPPORT_DIR=$SUPPORT_DIR"
  "DELTA_EXTERNAL_ACCEPTANCE_KIND=$KIND"
)

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
    COMMAND_ENV+=("DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH=$repository_dir")
    ;;
  sftp)
    repository_url="${DELTA_ACCEPTANCE_SFTP_REPOSITORY:-}"
    [[ -n "$repository_url" ]] || fail "DELTA_ACCEPTANCE_SFTP_REPOSITORY is required for SFTP acceptance." 64
    require_acceptance_remote "$repository_url"
    if [[ -n "${DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY:-}" ]]; then
      [[ -r "$DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY" ]] || fail "SFTP private key is not readable: $DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY"
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
    COMMAND_ENV+=("DELTA_EXTERNAL_ACCEPTANCE_REQUIRE_MISSING_CREDENTIAL_PROBE=1")
    ;;
esac

set +e
/usr/bin/env "${COMMAND_ENV[@]}" "$DELTA_EXECUTABLE" --acceptance-external-lifecycle >"$STDOUT_FILE" 2>"$STDERR_FILE"
STATUS=$?
set -e

if [[ "$STATUS" -ne 0 ]]; then
  {
    printf "# Delta External Backend Acceptance\n\n"
    printf "Installed external %s lifecycle acceptance failed.\n\n" "$KIND"
    printf -- "- App: %s\n" "$APP_PATH"
    printf -- "- Exit status: %s\n\n" "$STATUS"
    printf "## Standard Error\n\n"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n\n'
    printf "## Standard Output\n\n"
    printf '```text\n'
    /bin/cat "$STDOUT_FILE"
    printf '```\n'
  } >"$OUTPUT"
  printf "Installed external %s lifecycle acceptance failed. See %s\n" "$KIND" "$OUTPUT" >&2
  exit "$STATUS"
fi

if [[ -s "$STDERR_FILE" ]]; then
  {
    printf "# Delta External Backend Acceptance\n\n"
    printf "Installed external %s lifecycle acceptance failed because stderr was not empty.\n\n" "$KIND"
    printf '```text\n'
    /bin/cat "$STDERR_FILE"
    printf '```\n'
  } >"$OUTPUT"
  printf "Installed external %s lifecycle acceptance failed. See %s\n" "$KIND" "$OUTPUT" >&2
  exit 1
fi

/bin/cp "$STDOUT_FILE" "$OUTPUT"
for expected in \
  "Installed external $KIND lifecycle acceptance passed." \
  "Delta coordinator lifecycle: Yes" \
  "Automatic destination preparation runs: 1" \
  "No-change backup:" \
  "Incremental backup:" \
  "Restore browser entries verified:" \
  "Selected folder restore status:" \
  "Cleanup runs:"
do
  if ! /usr/bin/grep -Fq "$expected" "$OUTPUT"; then
    printf "Installed external lifecycle acceptance output was missing: %s\n" "$expected" >&2
    exit 1
  fi
done

LATEST_TMP="$OUTPUT_DIR/.external-$KIND-acceptance-latest.$$"
/bin/ln -s "$(basename "$OUTPUT")" "$LATEST_TMP"
/bin/mv -f "$LATEST_TMP" "$LATEST"

printf "Wrote installed external %s lifecycle acceptance to %s\n" "$KIND" "$OUTPUT"
printf "Updated %s\n" "$LATEST"
printf "Installed external %s lifecycle acceptance passed for %s\n" "$KIND" "$APP_PATH"
