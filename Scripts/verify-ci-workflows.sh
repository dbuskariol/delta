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
  run-installed-service-management-acceptance.sh \
  run-installed-time-machine-system-support-acceptance.sh \
  verify-time-machine-system-support-evidence.sh \
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

if /usr/bin/grep -Fq 'DELTA_VERIFY_INSTALLED_LAUNCH=1 "$ROOT_DIR/Scripts/verify-installed-app.sh" "$APP"' \
  "$ROOT_DIR/Scripts/verify-release-candidate.sh"; then
  printf "Release rehearsal must not launch a transient candidate with the installed app state.\n" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'Service Management acceptance requires an app installed directly in /Applications' \
  "$ROOT_DIR/Scripts/run-installed-service-management-acceptance.sh"; then
  printf "Service Management acceptance is missing its installed-identity guard.\n" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'requires the exact canonical app at /Applications/Delta.app' \
  "$ROOT_DIR/Scripts/run-installed-time-machine-system-support-acceptance.sh" \
  || ! /usr/bin/grep -Fq 'TimeMachineSetupHelperRuntimeVerifier.verify' \
    "$ROOT_DIR/Sources/Delta/DeltaApp.swift" \
  || ! /usr/bin/grep -Fq 'verify-time-machine-system-support-evidence.sh' \
    "$ROOT_DIR/Scripts/verify-production-readiness.sh"; then
  printf "Time Machine system-support release acceptance is missing its canonical-path, authenticated-helper, or publishing gate.\n" >&2
  exit 1
fi
if /usr/bin/grep -Fq 'run-installed-time-machine-system-support-acceptance.sh' \
  "$RELEASE_WORKFLOW"; then
  printf "Headless release automation must not pretend it can grant administrator approval to a Time Machine launch daemon.\n" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'run-local-acceptance-probe.sh" "$IDENTITY_ACCEPTANCE_APP_PATH"' \
  "$ROOT_DIR/Scripts/collect-release-evidence.sh"; then
  printf "Release evidence can run identity-sensitive acceptance against a transient candidate.\n" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'signature_value "$INSTALLED_APP_PATH" CDHash' \
  "$ROOT_DIR/Scripts/collect-release-evidence.sh"; then
  printf "Release evidence does not bind installed identity acceptance to the candidate CDHash.\n" >&2
  exit 1
fi
if ! /usr/bin/grep -Fq 'if [[ "$IS_INSTALLED_IDENTITY" == "1" ]]' \
  "$ROOT_DIR/Scripts/verify-installed-app.sh" \
  || ! /usr/bin/grep -Fq 'Scheduled service status skipped for transient candidate' \
    "$ROOT_DIR/Scripts/verify-installed-app.sh"; then
  printf "Transient candidate verification can still query Service Management.\n" >&2
  exit 1
fi

printf "CI workflow verified.\n"
