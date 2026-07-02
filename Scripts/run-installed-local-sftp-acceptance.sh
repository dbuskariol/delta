#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="${1:-${DELTA_ACCEPTANCE_APP:-/Applications/Delta.app}}"
WORK_DIR="$(/usr/bin/mktemp -d -t delta-sftp-local-acceptance.XXXXXX)"
SSHD_PID=""

cleanup() {
  if [[ -n "$SSHD_PID" ]]; then
    /bin/kill "$SSHD_PID" >/dev/null 2>&1 || true
    wait "$SSHD_PID" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$WORK_DIR"
}
trap cleanup EXIT

fail() {
  printf "%s\n" "$1" >&2
  if [[ -f "$WORK_DIR/sshd.log" ]]; then
    printf "\nsshd log:\n" >&2
    /bin/cat "$WORK_DIR/sshd.log" >&2
  fi
  exit "${2:-1}"
}

require_executable() {
  local path="$1"
  [[ -x "$path" ]] || fail "Required executable is missing: $path"
}

choose_port() {
  local port
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    port=$((40000 + RANDOM % 20000))
    if ! /usr/bin/nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
      printf "%s\n" "$port"
      return
    fi
  done
  return 1
}

require_executable /usr/sbin/sshd
require_executable /usr/bin/ssh
require_executable /usr/bin/ssh-keygen
require_executable /usr/libexec/sftp-server

if [[ ! -d "$APP_PATH" ]]; then
  fail "Delta app bundle not found at $APP_PATH"
fi

DELTA_EXECUTABLE="$APP_PATH/Contents/MacOS/Delta"
if [[ ! -x "$DELTA_EXECUTABLE" ]]; then
  fail "Delta executable is missing or not executable: $DELTA_EXECUTABLE"
fi

PORT="$(choose_port)" || fail "Could not find an available localhost port."
USER_NAME="$(/usr/bin/id -un)"
REMOTE_ROOT="$WORK_DIR/delta-acceptance-sftp"
REMOTE_REPOSITORY="$REMOTE_ROOT/repository"
REMOTE_MISSING="$REMOTE_ROOT/delta-acceptance-missing"
RESTIC_HOME="$WORK_DIR/restic-home"

/bin/chmod 700 "$WORK_DIR"
/bin/mkdir -p "$REMOTE_ROOT" "$RESTIC_HOME/.ssh"
/bin/chmod 700 "$RESTIC_HOME" "$RESTIC_HOME/.ssh"

/usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$WORK_DIR/host_ed25519" >/dev/null
/usr/bin/ssh-keygen -q -t ed25519 -N "" -f "$WORK_DIR/client_ed25519" >/dev/null
/bin/chmod 600 "$WORK_DIR/client_ed25519"
/bin/cp "$WORK_DIR/client_ed25519.pub" "$WORK_DIR/authorized_keys"
/bin/chmod 600 "$WORK_DIR/authorized_keys"

/usr/bin/printf "[127.0.0.1]:%s %s\n" "$PORT" "$(/bin/cat "$WORK_DIR/host_ed25519.pub")" >"$RESTIC_HOME/.ssh/known_hosts"
/bin/chmod 600 "$RESTIC_HOME/.ssh/known_hosts"

/bin/cat >"$WORK_DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK_DIR/host_ed25519
PidFile $WORK_DIR/sshd.pid
AuthorizedKeysFile $WORK_DIR/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
AllowUsers $USER_NAME
StrictModes no
UsePAM no
Subsystem sftp /usr/libexec/sftp-server
LogLevel ERROR
EOF

/usr/sbin/sshd -t -f "$WORK_DIR/sshd_config" || fail "Generated sshd configuration is invalid."
/usr/sbin/sshd -D -e -f "$WORK_DIR/sshd_config" >"$WORK_DIR/sshd.log" 2>&1 &
SSHD_PID=$!
/bin/sleep 1
if ! /bin/kill -0 "$SSHD_PID" >/dev/null 2>&1; then
  fail "Local SFTP server did not start."
fi

if ! HOME="$RESTIC_HOME" /usr/bin/ssh \
  -p "$PORT" \
  -i "$WORK_DIR/client_ed25519" \
  -o BatchMode=yes \
  -o IdentitiesOnly=yes \
  -o UserKnownHostsFile="$RESTIC_HOME/.ssh/known_hosts" \
  -o StrictHostKeyChecking=yes \
  "$USER_NAME@127.0.0.1" true >/dev/null 2>"$WORK_DIR/ssh-probe.stderr"
then
  /bin/cat "$WORK_DIR/ssh-probe.stderr" >&2
  fail "Local SFTP server did not accept non-interactive key authentication."
fi

DELTA_ACCEPTANCE_SFTP_REPOSITORY="sftp://$USER_NAME@127.0.0.1:$PORT/$REMOTE_REPOSITORY" \
DELTA_ACCEPTANCE_SFTP_PRIVATE_KEY="$WORK_DIR/client_ed25519" \
DELTA_ACCEPTANCE_SFTP_BAD_REPOSITORY="sftp://$USER_NAME@127.0.0.1:$PORT/$REMOTE_MISSING" \
DELTA_SFTP_KNOWN_HOSTS_FILE="$RESTIC_HOME/.ssh/known_hosts" \
  "$ROOT_DIR/Scripts/run-external-backend-acceptance.sh" sftp "$APP_PATH"

printf "Installed local SFTP lifecycle acceptance passed for %s\n" "$APP_PATH"
