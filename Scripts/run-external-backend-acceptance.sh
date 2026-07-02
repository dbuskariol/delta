#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND="${1:-}"
APP_PATH="${2:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
OUTPUT_DIR="${DELTA_EXTERNAL_ACCEPTANCE_DIR:-$ROOT_DIR/dist/local-acceptance}"

usage() {
  cat >&2 <<'EOF'
usage: Scripts/run-external-backend-acceptance.sh <mounted|sftp|rest|s3|b2|azure|gcs|swift|rclone|custom> [Delta.app]

Environment:
  mounted:
    DELTA_ACCEPTANCE_MOUNTED_PATH=/Volumes/YourMountedShare  must be a mounted network filesystem such as SMB or NFS

  sftp:
    DELTA_ACCEPTANCE_SFTP_REPOSITORY=sftp:user@example.com:/absolute/delta-acceptance-path
    DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY=/path/to/key   optional; ssh-agent/config also works
    DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY=...         optional; must fail before success
    DELTA_SFTP_KNOWN_HOSTS_FILE=/path/to/known_hosts optional; useful for isolated harnesses

  rest:
    DELTA_ACCEPTANCE_REST_REPOSITORY=rest:https://rest.example.com/delta-acceptance
    RESTIC_REST_USERNAME=...                         optional
    RESTIC_REST_PASSWORD=...                         optional

  s3:
    DELTA_ACCEPTANCE_S3_REPOSITORY=s3:https://endpoint/bucket/delta-acceptance-path
    AWS_ACCESS_KEY_ID=...
    AWS_SECRET_ACCESS_KEY=...
    AWS_SESSION_TOKEN=...                            optional
    AWS_DEFAULT_REGION=...                           optional

  b2:
    DELTA_ACCEPTANCE_B2_REPOSITORY=b2:bucket:delta-acceptance-path
    B2_ACCOUNT_ID=...
    B2_ACCOUNT_KEY=...

  azure:
    DELTA_ACCEPTANCE_AZURE_REPOSITORY=azure:container:/delta-acceptance-path
    AZURE_ACCOUNT_NAME=...
    AZURE_ACCOUNT_KEY=...                            either key or SAS is required
    AZURE_ACCOUNT_SAS=...
    AZURE_ENDPOINT_SUFFIX=...                        optional

  gcs:
    DELTA_ACCEPTANCE_GCS_REPOSITORY=gs:bucket:/delta-acceptance-path
    GOOGLE_APPLICATION_CREDENTIALS=/path/to/service-account.json
    GOOGLE_ACCESS_TOKEN=...                          alternatively use an access token
    GOOGLE_PROJECT_ID=...                            optional

  swift:
    DELTA_ACCEPTANCE_SWIFT_REPOSITORY=swift:container:/delta-acceptance-path
    Provide ST_AUTH/ST_USER/ST_KEY, OS_STORAGE_URL/OS_AUTH_TOKEN,
    Keystone password auth, or Keystone application credential auth.

  rclone:
    DELTA_ACCEPTANCE_RCLONE_REPOSITORY=rclone:remote:delta-acceptance-path
    RCLONE_CONFIG=/path/to/rclone.conf

  custom:
    DELTA_ACCEPTANCE_CUSTOM_REPOSITORY=<raw restic repository URL containing delta-acceptance>
    DELTA_ACCEPTANCE_CUSTOM_CREDENTIAL_KEYS=ENV_KEY,ANOTHER_ENV_KEY optional

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

mount_record_for_path() {
  local directory="$1"
  local line
  while IFS= read -r line; do
    case "$line" in
      *" on $directory ("*)
        printf "%s" "$line"
        return
        ;;
    esac
  done < <(/sbin/mount)
}

mount_filesystem_type() {
  local mount_record="$1"
  printf "%s" "$mount_record" | /usr/bin/sed -E 's/^.* \(([^,)]*).*$/\1/'
}

is_network_mount_type() {
  case "$1" in
    smbfs|nfs|nfs4|afpfs|webdav|fusefs.sshfs|sshfs)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
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

require_env() {
  local key="$1"
  [[ -n "${!key:-}" ]] || fail "$key is required for $KIND acceptance." 64
}

require_any_env() {
  local key
  for key in "$@"; do
    if [[ -n "${!key:-}" ]]; then
      return
    fi
  done
  fail "One of $* is required for $KIND acceptance." 64
}

require_readable_file_env() {
  local key="$1"
  require_env "$key"
  [[ -r "${!key}" ]] || fail "$key is not readable: ${!key}"
}

require_custom_credentials() {
  local raw_keys="${DELTA_ACCEPTANCE_CUSTOM_CREDENTIAL_KEYS:-}"
  local key
  raw_keys="${raw_keys//,/ }"
  for key in $raw_keys; do
    [[ -n "$key" ]] || continue
    [[ -n "${!key:-}" ]] || fail "$key is listed in DELTA_ACCEPTANCE_CUSTOM_CREDENTIAL_KEYS but is not set." 64
  done
}

has_all_env() {
  local key
  for key in "$@"; do
    [[ -n "${!key:-}" ]] || return 1
  done
}

has_any_env() {
  local key
  for key in "$@"; do
    [[ -n "${!key:-}" ]] && return 0
  done
  return 1
}

case "$KIND" in
  mounted|sftp|rest|s3|b2|azure|gcs|swift|rclone|custom)
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

is_loopback_repository() {
  case "$1" in
    *127.0.0.1*|*localhost*|*"::1"*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

acceptance_environment_for() {
  local kind="$1"
  local repository_url="$2"
  case "$kind" in
    mounted)
      printf "mounted-network"
      ;;
    sftp|rest|s3)
      if is_loopback_repository "$repository_url"; then
        printf "local-harness"
      else
        printf "real-external"
      fi
      ;;
    *)
      if is_loopback_repository "$repository_url"; then
        printf "local-harness"
      else
        printf "real-external"
      fi
      ;;
  esac
}

code_signature_value() {
  local app="$1"
  local key="$2"
  /usr/bin/codesign -dvvv "$app" 2>&1 | /usr/bin/awk -F= -v key="$key" '$1 == key && value == "" { value = $2 } END { print value }'
}

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
repository_url=""

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
        fail "Mounted acceptance path must live under /Volumes to prove mounted network-drive behavior."
        ;;
    esac
    mount_record="$(mount_record_for_path "$mounted_path")"
    [[ -n "$mount_record" ]] || fail "Mounted acceptance path was not found in the system mount table: $mounted_path"
    mount_type="$(mount_filesystem_type "$mount_record")"
    if ! is_network_mount_type "$mount_type"; then
      fail "Mounted acceptance path must be a network filesystem such as SMB or NFS. Found '$mount_type' for $mounted_path. Use local-drive acceptance for local external disks."
    fi
    probe_writable_directory "$mounted_path" || fail "Mounted acceptance path did not pass a write/delete probe: $mounted_path"
    repository_dir="$(/usr/bin/mktemp -d "$mounted_path/DeltaExternalAcceptance.XXXXXX")"
    CLEANUP_PATHS+=("$repository_dir")
    COMMAND_ENV+=("DELTA_ACCEPTANCE_MOUNTED_REPOSITORY_PATH=$repository_dir")
    repository_url="$repository_dir"
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
  rest)
    repository_url="${DELTA_ACCEPTANCE_REST_REPOSITORY:-}"
    require_env DELTA_ACCEPTANCE_REST_REPOSITORY
    require_acceptance_remote "$DELTA_ACCEPTANCE_REST_REPOSITORY"
    ;;
  s3)
    repository_url="${DELTA_ACCEPTANCE_S3_REPOSITORY:-}"
    [[ -n "$repository_url" ]] || fail "DELTA_ACCEPTANCE_S3_REPOSITORY is required for S3 acceptance." 64
    require_acceptance_remote "$repository_url"
    [[ -n "${AWS_ACCESS_KEY_ID:-}" ]] || fail "AWS_ACCESS_KEY_ID is required for S3 acceptance." 64
    [[ -n "${AWS_SECRET_ACCESS_KEY:-}" ]] || fail "AWS_SECRET_ACCESS_KEY is required for S3 acceptance." 64
    COMMAND_ENV+=("DELTA_EXTERNAL_ACCEPTANCE_REQUIRE_MISSING_CREDENTIAL_PROBE=1")
    ;;
  b2)
    repository_url="${DELTA_ACCEPTANCE_B2_REPOSITORY:-}"
    require_env DELTA_ACCEPTANCE_B2_REPOSITORY
    require_acceptance_remote "$DELTA_ACCEPTANCE_B2_REPOSITORY"
    require_env B2_ACCOUNT_ID
    require_env B2_ACCOUNT_KEY
    ;;
  azure)
    repository_url="${DELTA_ACCEPTANCE_AZURE_REPOSITORY:-}"
    require_env DELTA_ACCEPTANCE_AZURE_REPOSITORY
    require_acceptance_remote "$DELTA_ACCEPTANCE_AZURE_REPOSITORY"
    require_env AZURE_ACCOUNT_NAME
    require_any_env AZURE_ACCOUNT_KEY AZURE_ACCOUNT_SAS
    ;;
  gcs)
    repository_url="${DELTA_ACCEPTANCE_GCS_REPOSITORY:-}"
    require_env DELTA_ACCEPTANCE_GCS_REPOSITORY
    require_acceptance_remote "$DELTA_ACCEPTANCE_GCS_REPOSITORY"
    require_any_env GOOGLE_APPLICATION_CREDENTIALS GOOGLE_ACCESS_TOKEN
    if [[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ]]; then
      [[ -r "$GOOGLE_APPLICATION_CREDENTIALS" ]] || fail "GOOGLE_APPLICATION_CREDENTIALS is not readable: $GOOGLE_APPLICATION_CREDENTIALS"
    fi
    ;;
  swift)
    repository_url="${DELTA_ACCEPTANCE_SWIFT_REPOSITORY:-}"
    require_env DELTA_ACCEPTANCE_SWIFT_REPOSITORY
    require_acceptance_remote "$DELTA_ACCEPTANCE_SWIFT_REPOSITORY"
    if has_all_env ST_AUTH ST_USER ST_KEY \
      || has_all_env OS_STORAGE_URL OS_AUTH_TOKEN \
      || { has_any_env OS_USERNAME OS_USER_ID && has_all_env OS_AUTH_URL OS_PASSWORD; } \
      || { has_any_env OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_NAME && has_all_env OS_AUTH_URL OS_APPLICATION_CREDENTIAL_SECRET; }
    then
      :
    else
      fail "Swift acceptance requires ST_AUTH/ST_USER/ST_KEY, OS_STORAGE_URL/OS_AUTH_TOKEN, Keystone password auth, or Keystone application credential auth." 64
    fi
    ;;
  rclone)
    repository_url="${DELTA_ACCEPTANCE_RCLONE_REPOSITORY:-}"
    require_env DELTA_ACCEPTANCE_RCLONE_REPOSITORY
    require_acceptance_remote "$DELTA_ACCEPTANCE_RCLONE_REPOSITORY"
    require_readable_file_env RCLONE_CONFIG
    ;;
  custom)
    repository_url="${DELTA_ACCEPTANCE_CUSTOM_REPOSITORY:-}"
    require_env DELTA_ACCEPTANCE_CUSTOM_REPOSITORY
    require_acceptance_remote "$DELTA_ACCEPTANCE_CUSTOM_REPOSITORY"
    require_custom_credentials
    ;;
esac

ACCEPTANCE_ENVIRONMENT="$(acceptance_environment_for "$KIND" "$repository_url")"

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
{
  printf "\n## Acceptance Provenance\n\n"
  printf -- "- Runner: Scripts/run-external-backend-acceptance.sh\n"
  printf -- "- Git Commit: %s\n" "$(/usr/bin/git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || printf "unknown")"
  printf -- "- Acceptance environment: %s\n" "$ACCEPTANCE_ENVIRONMENT"
  printf -- "- App CDHash: %s\n" "$(code_signature_value "$APP_PATH" CDHash)"
} >>"$OUTPUT"
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
