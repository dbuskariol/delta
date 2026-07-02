#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_STRING_FILES=(
  "Sources/Delta/ContentView.swift"
  "Sources/Delta/DeltaAppModel.swift"
  "Sources/Delta/MenuBarStatusView.swift"
  "Sources/Delta/SoftwareUpdateController.swift"
  "Sources/DeltaCore/DiagnosticReport.swift"
  "Sources/DeltaCore/KeychainSecretStore.swift"
  "Sources/DeltaCore/LaunchAgentController.swift"
  "Sources/DeltaCore/ResticRunner.swift"
  "Sources/DeltaCore/SettingsSurfaceContract.swift"
)

UI_STRING_VIOLATIONS="$(
  for file in "${APP_STRING_FILES[@]}"; do
    /usr/bin/perl -ne '
      my $visible = $_;
      $visible =~ s/\\\([^)]*\)//g;
      if ($visible =~ /"(?:[^"\\]|\\.)*(?:\b(?:Repositories|Repository|LaunchAgent)\b|repository passwords?|repository secrets?|repository-secrets|\bLaunch Agent\b|\blaunch agent\b|\brestic work\b|backup\.example\.com\/repo|\/repo\b)(?:[^"\\]|\\.)*"/) {
        print "$ARGV:$.:$_";
      }
    ' "$file"
  done
)"

if [[ -n "$UI_STRING_VIOLATIONS" ]]; then
  printf "%s" "$UI_STRING_VIOLATIONS"
  printf "User-facing app strings must use Delta product language: Destinations, Restore Points, and Background Backups.\n" >&2
  exit 1
fi

PRODUCT_LANGUAGE_FILES=(
  README.md
  docs
  Sources
  Packaging
  "Scripts/build-app.sh"
  "Scripts/generate-appcast.sh"
  "Scripts/install-app.sh"
  "Scripts/package-update.sh"
  "Scripts/verify-release.sh"
  "Scripts/verify-restic-surface.sh"
  "Scripts/verify-tools.sh"
)

if /opt/homebrew/bin/rg -n "repository-secrets|Delta repository secrets|Repair Keychain Access|com\\.delta\\.backup\\.secrets" \
  "${PRODUCT_LANGUAGE_FILES[@]}" 2>/dev/null ||
  /usr/bin/grep -REn "repository-secrets|Delta repository secrets|Repair Keychain Access|com\\.delta\\.backup\\.secrets" \
  "${PRODUCT_LANGUAGE_FILES[@]}" 2>/dev/null; then
  printf "Old repository-oriented Keychain or settings wording is not allowed.\n" >&2
  exit 1
fi

printf "Product language verified.\n"
