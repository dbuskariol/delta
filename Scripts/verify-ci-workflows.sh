#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
RELEASE_WORKFLOW="$ROOT_DIR/.github/workflows/release.yml"
REHEARSAL_WORKFLOW="$ROOT_DIR/.github/workflows/release-rehearsal.yml"

if [[ ! -f "$WORKFLOW" ]]; then
  printf "GitHub Actions CI workflow is missing at %s\n" "$WORKFLOW" >&2
  exit 1
fi

if ! /usr/bin/ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$WORKFLOW"; then
  printf "GitHub Actions CI workflow YAML could not be parsed: %s\n" "$WORKFLOW" >&2
  exit 1
fi

for required in \
  "runner: [macos-26, macos-26-intel]" \
  "permissions:" \
  "contents: read" \
  "concurrency:" \
  "Scripts/verify-ci.sh"
do
  if ! /usr/bin/grep -Fq "$required" "$WORKFLOW"; then
    printf "GitHub Actions CI workflow is missing required entry: %s\n" "$required" >&2
    exit 1
  fi
done

if [[ ! -f "$REHEARSAL_WORKFLOW" ]] \
  || ! /usr/bin/grep -Fq 'Scripts/release.sh prepare' "$REHEARSAL_WORKFLOW" \
  || ! /usr/bin/grep -Fq 'DELTA_RELEASE_REHEARSAL_ENABLED' "$REHEARSAL_WORKFLOW"; then
  printf "Fail-closed release rehearsal workflow is missing or incomplete.\n" >&2
  exit 1
fi

if [[ ! -f "$RELEASE_WORKFLOW" ]]; then
  printf "GitHub Actions release workflow is missing at %s\n" "$RELEASE_WORKFLOW" >&2
  exit 1
fi
if ! /usr/bin/ruby -e 'require "yaml"; YAML.load_file(ARGV.fetch(0))' "$RELEASE_WORKFLOW"; then
  printf "GitHub Actions release workflow YAML could not be parsed: %s\n" "$RELEASE_WORKFLOW" >&2
  exit 1
fi
for required in \
  "DELTA_RELEASE_AUTOMATION_ENABLED" \
  "Scripts/release.sh finalize" \
  "Scripts/publish-release.sh" \
  "persist-credentials: false"
do
  if ! /usr/bin/grep -Fq "$required" "$RELEASE_WORKFLOW"; then
    printf "GitHub Actions release workflow is missing required entry: %s\n" "$required" >&2
    exit 1
  fi
done

for script in \
  audit-release-history.sh build-app.sh build-release.sh create-dmg.sh \
  create-release-manifest.sh generate-appcast.sh notarize-release.sh \
  package-update.sh publish-release.sh release.sh verify-release-assets.sh \
  verify-release-candidate.sh verify-production-readiness.sh \
  verify-sparkle-update.sh
do
  /bin/bash -n "$ROOT_DIR/Scripts/$script"
done

if ! /usr/bin/grep -Fq '"$ROOT_DIR/Scripts/verify-production-readiness.sh"' \
  "$ROOT_DIR/Scripts/publish-release.sh"; then
  printf "Release publishing does not enforce the production-readiness gate.\n" >&2
  exit 1
fi

printf "CI workflow verified.\n"
