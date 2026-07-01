#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/Resources/Tools/tools.json"
BUILD_DIR="$ROOT_DIR/.build/tool-bootstrap"
OUTPUT_DIR="$ROOT_DIR/Resources/Tools/bin"

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

json_value() {
  /usr/bin/python3 - "$MANIFEST" "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

value = data
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

download() {
  local url="$1"
  local destination="$2"
  if [[ ! -f "$destination" ]]; then
    /usr/bin/curl --fail --location --show-error --silent "$url" --output "$destination"
  fi
}

verify_checksum() {
  local checksums_file="$1"
  local artifact="$2"
  local artifact_name
  artifact_name="$(basename "$artifact")"
  /usr/bin/grep "  $artifact_name\$" "$checksums_file" > "$artifact.sha256"
  (cd "$(dirname "$artifact")" && /usr/bin/shasum -a 256 -c "$(basename "$artifact.sha256")")
}

bootstrap_restic() {
  local version checksums_url checksums_file arm_url amd_url arm_archive amd_archive arm_bin amd_bin
  version="$(json_value restic.version)"
  checksums_url="$(json_value restic.checksums)"
  checksums_file="$BUILD_DIR/restic-SHA256SUMS"
  arm_url="$(json_value restic.darwin.arm64)"
  amd_url="$(json_value restic.darwin.amd64)"
  arm_archive="$BUILD_DIR/$(basename "$arm_url")"
  amd_archive="$BUILD_DIR/$(basename "$amd_url")"
  arm_bin="$BUILD_DIR/restic-arm64"
  amd_bin="$BUILD_DIR/restic-amd64"

  download "$checksums_url" "$checksums_file"
  download "$arm_url" "$arm_archive"
  download "$amd_url" "$amd_archive"
  verify_checksum "$checksums_file" "$arm_archive"
  verify_checksum "$checksums_file" "$amd_archive"

  /usr/bin/bzip2 -dc "$arm_archive" > "$arm_bin"
  /usr/bin/bzip2 -dc "$amd_archive" > "$amd_bin"
  /bin/chmod 755 "$arm_bin" "$amd_bin"
  /usr/bin/lipo -create "$arm_bin" "$amd_bin" -output "$OUTPUT_DIR/restic"
  /bin/chmod 755 "$OUTPUT_DIR/restic"
  (cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 restic > restic.sha256)
  "$OUTPUT_DIR/restic" version
  printf "restic %s installed at %s\n" "$version" "$OUTPUT_DIR/restic"
}

bootstrap_rclone() {
  local version checksums_url checksums_file arm_url amd_url arm_archive amd_archive arm_dir amd_dir arm_bin amd_bin
  version="$(json_value rclone.version)"
  checksums_url="$(json_value rclone.checksums)"
  checksums_file="$BUILD_DIR/rclone-SHA256SUMS"
  arm_url="$(json_value rclone.darwin.arm64)"
  amd_url="$(json_value rclone.darwin.amd64)"
  arm_archive="$BUILD_DIR/$(basename "$arm_url")"
  amd_archive="$BUILD_DIR/$(basename "$amd_url")"
  arm_dir="$BUILD_DIR/rclone-arm64"
  amd_dir="$BUILD_DIR/rclone-amd64"
  arm_bin="$arm_dir/rclone-v$version-osx-arm64/rclone"
  amd_bin="$amd_dir/rclone-v$version-osx-amd64/rclone"

  download "$checksums_url" "$checksums_file"
  download "$arm_url" "$arm_archive"
  download "$amd_url" "$amd_archive"
  verify_checksum "$checksums_file" "$arm_archive"
  verify_checksum "$checksums_file" "$amd_archive"

  rm -rf "$arm_dir" "$amd_dir"
  mkdir -p "$arm_dir" "$amd_dir"
  /usr/bin/unzip -q "$arm_archive" -d "$arm_dir"
  /usr/bin/unzip -q "$amd_archive" -d "$amd_dir"
  /usr/bin/lipo -create "$arm_bin" "$amd_bin" -output "$OUTPUT_DIR/rclone"
  /bin/chmod 755 "$OUTPUT_DIR/rclone"
  (cd "$OUTPUT_DIR" && /usr/bin/shasum -a 256 rclone > rclone.sha256)
  "$OUTPUT_DIR/rclone" version | /usr/bin/head -n 1
  printf "rclone %s installed at %s\n" "$version" "$OUTPUT_DIR/rclone"
}

bootstrap_restic
bootstrap_rclone
