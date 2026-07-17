#!/usr/bin/env bash

# Shared, fail-closed release invariants. Every script that can create a
# distributable Delta artifact sources this file so local and CI releases are
# held to the same standard.

if [[ -n "${DELTA_RELEASE_LIB_LOADED:-}" ]]; then
  return 0
fi
readonly DELTA_RELEASE_LIB_LOADED=1

readonly DELTA_EXPECTED_BUNDLE_ID="com.delta.backup"
readonly DELTA_EXPECTED_MINIMUM_SYSTEM="26.0"
readonly DELTA_EXPECTED_ARCHITECTURES=(arm64 x86_64)
readonly DELTA_EXPECTED_TEAM_ID="${DELTA_DEVELOPMENT_TEAM:-BJCVJ5G7MJ}"
readonly DELTA_EXPECTED_SIGNING_IDENTITY="Developer ID Application: Daniel Buskariol (BJCVJ5G7MJ)"
readonly DELTA_EXPECTED_GITHUB_REPOSITORY="${DELTA_GITHUB_REPOSITORY:-dbuskariol/delta}"
readonly DELTA_EXPECTED_FEED_URL="https://github.com/$DELTA_EXPECTED_GITHUB_REPOSITORY/releases/latest/download/appcast.xml"

delta_fail() {
  printf 'Delta release error: %s\n' "$1" >&2
  exit 1
}

delta_note() {
  printf '==> %s\n' "$1"
}

delta_default_derived_data() {
  local purpose="$1"
  local base="${DELTA_DERIVED_DATA_ROOT:-${HOME:?}/Library/Developer/Xcode/DerivedData/Delta}"

  # Build and test hosts are executable code. Keep them out of protected user
  # folders so macOS never mistakes routine verification for Documents access.
  printf '%s/%s\n' "$base" "$purpose"
}

delta_require_tool() {
  /usr/bin/command -v "$1" >/dev/null 2>&1 || delta_fail "required tool is unavailable: $1"
}

delta_plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null || true
}

delta_json_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

delta_notarization_submission_path() {
  local output_dir="$1"
  local artifact="$2"
  local version="$3"
  local build="$4"

  case "$artifact" in
    app|dmg) ;;
    *) delta_fail "unsupported notarization artifact kind: $artifact" ;;
  esac
  printf '%s/notary-submit-%s-%s-%s.json\n' "$output_dir" "$artifact" "$version" "$build"
}

delta_notarization_log_path() {
  local output_dir="$1"
  local artifact="$2"
  local version="$3"
  local build="$4"

  case "$artifact" in
    app|dmg) ;;
    *) delta_fail "unsupported notarization artifact kind: $artifact" ;;
  esac
  printf '%s/notary-log-%s-%s-%s.json\n' "$output_dir" "$artifact" "$version" "$build"
}

delta_verify_notarization_record() {
  local output_dir="$1"
  local artifact="$2"
  local version="$3"
  local build="$4"
  local submission_json log_json

  submission_json="$(delta_notarization_submission_path "$output_dir" "$artifact" "$version" "$build")"
  log_json="$(delta_notarization_log_path "$output_dir" "$artifact" "$version" "$build")"
  [[ -f "$submission_json" && -f "$log_json" ]] || return 1
  [[ "$(delta_json_value status "$submission_json")" == "Accepted" ]] || return 1
  [[ "$(delta_json_value status "$log_json")" == "Accepted" ]] || return 1
}

delta_first_markdown_heading() {
  local document="$1"
  /usr/bin/awk '/^# / { print; exit }' "$document" 2>/dev/null || true
}

delta_codesign_details() {
  /usr/bin/codesign -dvvv --verbose=4 "$1" 2>&1
}

delta_signature_team() {
  /usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$(delta_codesign_details "$1")"
}

delta_signature_cdhash() {
  /usr/bin/awk -F= '/^CDHash=/{print $2; exit}' <<<"$(delta_codesign_details "$1")"
}

delta_record_automated_gate_status() {
  local root="$1"
  local app="$2"
  local mode="$3"
  local output_dir="$root/dist/release-evidence"
  local output="$output_dir/automated-gate-status"
  local temporary
  local app_path
  local app_cdhash
  local git_commit

  [[ -d "$app" ]] || delta_fail "cannot record automated gate status without the verified app: $app"
  app_path="$(cd "$(dirname "$app")" && pwd -P)/$(basename "$app")"
  app_cdhash="$(delta_signature_cdhash "$app_path")"
  [[ -n "$app_cdhash" ]] || delta_fail "cannot record automated gate status without an app CDHash: $app_path"
  git_commit="$(/usr/bin/git -C "$root" rev-parse --short HEAD)"
  [[ -n "$git_commit" ]] || delta_fail 'cannot record automated gate status without a git commit'

  /bin/mkdir -p "$output_dir"
  temporary="$(/usr/bin/mktemp "$output_dir/.automated-gate-status.XXXXXX")"
  {
    printf 'status=Passed\n'
    printf 'git_commit=%s\n' "$git_commit"
    printf 'app_path=%s\n' "$app_path"
    printf 'app_cdhash=%s\n' "$app_cdhash"
    printf 'mode=%s\n' "$mode"
    printf 'recorded_at=%s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$temporary"
  /bin/mv -f "$temporary" "$output"
  delta_note "Recorded the automated gate for $git_commit and app CDHash $app_cdhash"
}

delta_assert_developer_id_signature() {
  local signed_path="$1"
  local expected_team="${2:-}"
  local require_hardened_runtime="${3:-0}"
  local signing_details team

  /usr/bin/codesign --verify --strict --verbose=2 "$signed_path" \
    || delta_fail "the code signature is invalid: $signed_path"
  signing_details="$(delta_codesign_details "$signed_path")"
  /usr/bin/grep -q '^Authority=Developer ID Application:' <<<"$signing_details" \
    || delta_fail "Developer ID Application did not sign: $signed_path"
  /usr/bin/grep -Eq '^Timestamp=.+$' <<<"$signing_details" \
    || delta_fail "the signature is missing a trusted timestamp: $signed_path"
  if [[ "$require_hardened_runtime" == "1" ]]; then
    /usr/bin/grep -Eq '^CodeDirectory .*flags=.*\(runtime\)' <<<"$signing_details" \
      || delta_fail "the hardened runtime is not enabled: $signed_path"
  fi
  team="$(/usr/bin/awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$signing_details")"
  [[ -n "$team" && "$team" != "not set" ]] \
    || delta_fail "the signature is missing its team identifier: $signed_path"
  if [[ -n "$expected_team" && "$team" != "$expected_team" ]]; then
    delta_fail "signature team $team does not match expected team $expected_team: $signed_path"
  fi

  local entitlements key value
  entitlements="$(/usr/bin/mktemp -t delta-code-entitlements.XXXXXX)"
  if /usr/bin/codesign -d --entitlements :- "$signed_path" >"$entitlements" 2>/dev/null; then
    for key in \
      com.apple.security.get-task-allow \
      com.apple.security.cs.allow-jit \
      com.apple.security.cs.allow-unsigned-executable-memory \
      com.apple.security.cs.disable-executable-page-protection \
      com.apple.security.cs.disable-library-validation
    do
      value="$(delta_plist_value "$key" "$entitlements")"
      [[ "$value" != "true" ]] \
        || { /bin/rm -f "$entitlements"; delta_fail "release code contains forbidden entitlement $key: $signed_path"; }
    done
  fi
  /bin/rm -f "$entitlements"
}

delta_find_developer_id_identity() {
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F\" -v expected="$DELTA_EXPECTED_SIGNING_IDENTITY" '$2 == expected { print $2; exit }'
}

delta_assert_clean_worktree() {
  local root="$1"
  if [[ "${DELTA_ALLOW_DIRTY:-0}" == "1" ]]; then
    return 0
  fi
  [[ -z "$(/usr/bin/git -C "$root" status --porcelain --untracked-files=normal)" ]] \
    || delta_fail 'the worktree is dirty; commit the verified release source first (or set DELTA_ALLOW_DIRTY=1 for a non-shipping rehearsal)'
}

delta_assert_release_metadata() {
  local root="$1"
  local settings version build notes_heading tag
  settings="$(/usr/bin/xcodebuild \
    -project "$root/Delta.xcodeproj" \
    -scheme Delta \
    -configuration Release \
    -showBuildSettings 2>/dev/null)"
  version="$(/usr/bin/awk '/MARKETING_VERSION =/{print $3; exit}' <<<"$settings")"
  build="$(/usr/bin/awk '/CURRENT_PROJECT_VERSION =/{print $3; exit}' <<<"$settings")"

  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
    || delta_fail "MARKETING_VERSION is not a release version: ${version:-missing}"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] \
    || delta_fail "CURRENT_PROJECT_VERSION must be a positive integer: ${build:-missing}"

  notes_heading="$(/usr/bin/sed -n '1p' "$root/Documentation/RELEASE_NOTES.md" 2>/dev/null || true)"
  [[ "$notes_heading" == "# Delta $version" ]] \
    || delta_fail "release notes must start with '# Delta $version'"

  tag="${DELTA_RELEASE_TAG:-}"
  if [[ -z "$tag" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
    tag="${GITHUB_REF_NAME:-}"
  fi
  if [[ -z "$tag" ]]; then
    tag="$(/usr/bin/git -C "$root" describe --tags --exact-match 2>/dev/null || true)"
  fi
  if [[ -n "$tag" ]]; then
    [[ "$tag" == "v$version" ]] \
      || delta_fail "release tag $tag does not match MARKETING_VERSION $version"
  elif [[ "${DELTA_REQUIRE_RELEASE_TAG:-0}" == "1" ]]; then
    delta_fail "a v$version release tag is required"
  fi

  if [[ "${DELTA_REQUIRE_RELEASE_TAG:-0}" == "1" ]]; then
    [[ "$(/usr/bin/git -C "$root" cat-file -t "refs/tags/$tag" 2>/dev/null || true)" == "tag" ]] \
      || delta_fail "$tag must be an annotated tag"
    [[ "$(/usr/bin/git -C "$root" rev-list -n 1 "$tag")" == "$(/usr/bin/git -C "$root" rev-parse HEAD)" ]] \
      || delta_fail "$tag does not point to the checked-out release commit"
    tagger="$(/usr/bin/git -C "$root" for-each-ref --format='%(taggername)|%(taggeremail)' "refs/tags/$tag")"
    [[ "$tagger" == "dbuskariol|<32349796+dbuskariol@users.noreply.github.com>" ]] \
      || delta_fail "$tag tagger identity is not dbuskariol <32349796+dbuskariol@users.noreply.github.com>"
  fi

  printf '%s\t%s\n' "$version" "$build"
}

delta_assert_release_app() {
  local app="$1"
  local expected_team="${2:-}"
  local expected_version="${DELTA_EXPECTED_RELEASE_VERSION:-}"
  local expected_build="${DELTA_EXPECTED_RELEASE_BUILD:-}"
  local info executable bundle_id minimum_system version build architectures team

  [[ -d "$app" ]] || delta_fail "app bundle not found: $app"
  info="$app/Contents/Info.plist"
  [[ -f "$info" ]] || delta_fail "Info.plist is missing from $app"
  /usr/bin/plutil -lint "$info" >/dev/null || delta_fail 'Info.plist is invalid'

  bundle_id="$(delta_plist_value CFBundleIdentifier "$info")"
  minimum_system="$(delta_plist_value LSMinimumSystemVersion "$info")"
  version="$(delta_plist_value CFBundleShortVersionString "$info")"
  build="$(delta_plist_value CFBundleVersion "$info")"
  executable="$app/Contents/MacOS/$(delta_plist_value CFBundleExecutable "$info")"

  [[ "$bundle_id" == "$DELTA_EXPECTED_BUNDLE_ID" ]] \
    || delta_fail "unexpected bundle identifier: ${bundle_id:-missing}"
  [[ "$minimum_system" == "$DELTA_EXPECTED_MINIMUM_SYSTEM" ]] \
    || delta_fail "minimum system must be macOS $DELTA_EXPECTED_MINIMUM_SYSTEM"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] \
    || delta_fail "invalid app version: ${version:-missing}"
  [[ "$build" =~ ^[1-9][0-9]*$ ]] \
    || delta_fail "invalid app build: ${build:-missing}"
  if [[ -n "$expected_version" && "$version" != "$expected_version" ]]; then
    delta_fail "app version $version does not match release version $expected_version"
  fi
  if [[ -n "$expected_build" && "$build" != "$expected_build" ]]; then
    delta_fail "app build $build does not match release build $expected_build"
  fi
  [[ -x "$executable" ]] || delta_fail "main executable is missing: $executable"

  /usr/bin/codesign --verify --strict --deep --verbose=2 "$app" \
    || delta_fail 'the app signature is invalid'
  [[ -n "$expected_team" ]] || expected_team="$DELTA_EXPECTED_TEAM_ID"
  delta_assert_developer_id_signature "$app" "$expected_team" 1
  team="$(delta_signature_team "$app")"

  architectures="$(/usr/bin/lipo -archs "$executable")"
  local architecture
  for architecture in "${DELTA_EXPECTED_ARCHITECTURES[@]}"; do
    [[ " $architectures " == *" $architecture "* ]] \
      || delta_fail "the release is missing $architecture (found: $architectures)"
  done

  [[ -f "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" ]] \
    || delta_fail 'the embedded Sparkle framework is missing'
  local agent_plist="$app/Contents/Library/LaunchAgents/com.delta.backup.agent.plist"
  [[ -f "$agent_plist" ]] || delta_fail 'the scheduled-backup property list is missing'
  [[ "$(/usr/bin/plutil -extract BundleProgram raw -o - "$agent_plist")" == "Contents/Resources/DeltaAgent" ]] \
    || delta_fail 'the scheduled-backup executable is not in the Service Management resource location'
  [[ ! -e "$app/Contents/MacOS/DeltaAgent" ]] \
    || delta_fail 'the obsolete scheduled-backup executable location remains in the app'
  local signed_code code_architectures
  for signed_code in \
    "$app/Contents/MacOS/Delta" \
    "$app/Contents/Resources/DeltaAgent" \
    "$app/Contents/MacOS/DeltaSecretBridge" \
    "$app/Contents/MacOS/restic" \
    "$app/Contents/MacOS/rclone" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
    "$app/Contents/Frameworks/Sparkle.framework"
  do
    [[ -e "$signed_code" ]] || delta_fail "required signed code is missing: $signed_code"
    delta_assert_developer_id_signature "$signed_code" "$team" 1
  done
  for signed_code in \
    "$app/Contents/MacOS/Delta" \
    "$app/Contents/Resources/DeltaAgent" \
    "$app/Contents/MacOS/DeltaSecretBridge" \
    "$app/Contents/MacOS/restic" \
    "$app/Contents/MacOS/rclone" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
    "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
  do
    [[ -f "$signed_code" ]] || delta_fail "required executable is missing: $signed_code"
    delta_assert_developer_id_signature "$signed_code" "$team" 1
    code_architectures="$(/usr/bin/lipo -archs "$signed_code")"
    for architecture in "${DELTA_EXPECTED_ARCHITECTURES[@]}"; do
      [[ " $code_architectures " == *" $architecture "* ]] \
        || delta_fail "release code is missing $architecture (found: $code_architectures): $signed_code"
    done
  done
  local privacy_manifest="$app/Contents/Resources/PrivacyInfo.xcprivacy"
  [[ -f "$privacy_manifest" ]] || delta_fail 'the app privacy manifest is missing'
  /usr/bin/plutil -lint "$privacy_manifest" >/dev/null \
    || delta_fail 'the app privacy manifest is invalid'
  [[ "$(delta_plist_value NSPrivacyTracking "$privacy_manifest")" == "false" ]] \
    || delta_fail 'the app privacy manifest unexpectedly declares tracking'
  [[ "$(/usr/bin/plutil -extract NSPrivacyCollectedDataTypes raw -o - "$privacy_manifest")" == "0" ]] \
    || delta_fail 'the app privacy manifest unexpectedly declares collected data'
  [[ "$(/usr/bin/plutil -extract NSPrivacyTrackingDomains raw -o - "$privacy_manifest")" == "0" ]] \
    || delta_fail 'the app privacy manifest unexpectedly declares tracking domains'
  local privacy_dump
  privacy_dump="$(/usr/bin/plutil -p "$privacy_manifest")"
  for required_privacy_value in \
    NSPrivacyAccessedAPICategoryDiskSpace 85F4.1 \
    NSPrivacyAccessedAPICategoryUserDefaults CA92.1
  do
    /usr/bin/grep -Fq "$required_privacy_value" <<<"$privacy_dump" \
      || delta_fail "the privacy manifest is missing $required_privacy_value"
  done
  local feed_url public_key
  feed_url="$(delta_plist_value SUFeedURL "$info")"
  public_key="$(delta_plist_value SUPublicEDKey "$info")"
  [[ "$feed_url" == "$DELTA_EXPECTED_FEED_URL" ]] \
    || delta_fail "unexpected Sparkle feed URL: ${feed_url:-missing}"
  [[ "$public_key" =~ ^[A-Za-z0-9+/=]{40,}$ ]] \
    || delta_fail 'the Sparkle EdDSA public key is invalid'
  [[ "$(delta_plist_value SURequireSignedFeed "$info")" == "true" ]] \
    || delta_fail 'signed Sparkle feeds are not required by the app'
  [[ "$(delta_plist_value SUVerifyUpdateBeforeExtraction "$info")" == "true" ]] \
    || delta_fail 'Sparkle update verification before extraction is disabled'
}

delta_assert_notarized_app() {
  local app="$1"
  /usr/bin/xcrun stapler validate "$app" >/dev/null \
    || delta_fail 'the app does not contain a valid stapled notarization ticket'
  /usr/sbin/spctl --assess --type execute --verbose=4 "$app" \
    || delta_fail 'Gatekeeper rejected the app'
}

delta_assert_signed_disk_image() {
  local disk_image="$1"
  local expected_team="${2:-}"

  [[ -f "$disk_image" ]] || delta_fail "disk image not found: $disk_image"
  /usr/bin/hdiutil verify "$disk_image" >/dev/null \
    || delta_fail 'the disk image failed its integrity check'
  delta_assert_developer_id_signature "$disk_image" "$expected_team"
}

delta_assert_notarized_disk_image() {
  local disk_image="$1"
  local expected_team="${2:-}"

  delta_assert_signed_disk_image "$disk_image" "$expected_team"
  /usr/bin/xcrun stapler validate "$disk_image" >/dev/null \
    || delta_fail 'the disk image does not contain a valid stapled notarization ticket'
  /usr/sbin/spctl \
    --assess \
    --type open \
    --context context:primary-signature \
    --verbose=4 \
    "$disk_image" \
    || delta_fail 'Gatekeeper rejected the disk image'
}

DELTA_NOTARY_ARGS=()

delta_configure_notary_credentials() {
  DELTA_NOTARY_ARGS=()
  if [[ -n "${DELTA_NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    DELTA_NOTARY_ARGS=(--keychain-profile "$DELTA_NOTARY_KEYCHAIN_PROFILE")
  elif [[ -n "${DELTA_NOTARY_KEY_PATH:-}" \
    && -n "${DELTA_NOTARY_KEY_ID:-}" \
    && -n "${DELTA_NOTARY_ISSUER_ID:-}" ]]; then
    [[ -f "$DELTA_NOTARY_KEY_PATH" ]] \
      || delta_fail "App Store Connect API key is missing: $DELTA_NOTARY_KEY_PATH"
    DELTA_NOTARY_ARGS=(
      --key "$DELTA_NOTARY_KEY_PATH"
      --key-id "$DELTA_NOTARY_KEY_ID"
      --issuer "$DELTA_NOTARY_ISSUER_ID"
    )
  else
    /bin/cat >&2 <<'EOF'
Notarization credentials are not configured. Use a stored Keychain profile:

  DELTA_NOTARY_KEYCHAIN_PROFILE="Reccy Notary" Scripts/release.sh finalize

CI may instead provide DELTA_NOTARY_KEY_PATH, DELTA_NOTARY_KEY_ID, and
DELTA_NOTARY_ISSUER_ID. Passwords and Apple IDs are never accepted inline.
EOF
    exit 1
  fi
}

delta_submit_notarization() {
  local artifact="$1"
  local submission_json="$2"
  local log_json="$3"
  local submission_id status log_status issue_count issue_type

  delta_configure_notary_credentials
  /bin/rm -f "$submission_json" "$log_json"
  /usr/bin/xcrun notarytool submit \
    "$artifact" \
    "${DELTA_NOTARY_ARGS[@]}" \
    --wait \
    --output-format json >"$submission_json"

  submission_id="$(delta_json_value id "$submission_json")"
  status="$(delta_json_value status "$submission_json")"
  [[ -n "$submission_id" ]] || delta_fail 'Apple notarization returned no submission identifier'
  /usr/bin/xcrun notarytool log \
    "$submission_id" \
    "$log_json" \
    "${DELTA_NOTARY_ARGS[@]}" \
    >/dev/null

  log_status="$(delta_json_value status "$log_json")"
  if ! issue_count="$(/usr/bin/plutil -extract issues raw -o - "$log_json" 2>/dev/null)"; then
    issue_type="$(/usr/bin/plutil -type issues "$log_json" 2>/dev/null || true)"
    [[ "$issue_type" == "(any)" ]] \
      || delta_fail "Apple's notarization log has an unreadable issues field; inspect $log_json"
    issue_count=0
  fi
  [[ "$status" == "Accepted" && "$log_status" == "Accepted" ]] \
    || delta_fail "notarization failed with status ${status:-unknown}; inspect $log_json"
  [[ "$issue_count" == "0" ]] \
    || delta_fail "notarization reported ${issue_count:-unknown} issues; inspect $log_json"
}

delta_resolve_sparkle_tool() {
  local root="$1"
  local derived_data="$2"
  local tool="$3"
  local path="$derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin/$tool"
  if [[ ! -x "$path" ]]; then
    /usr/bin/xcodebuild \
      -project "$root/Delta.xcodeproj" \
      -scheme Delta \
      -configuration Release \
      -destination 'generic/platform=macOS' \
      -derivedDataPath "$derived_data" \
      -resolvePackageDependencies >/dev/null
  fi
  [[ -x "$path" ]] || delta_fail "Sparkle tool was not resolved: $tool"
  printf '%s\n' "$path"
}

delta_assert_sparkle_signing_key() {
  local root="$1"
  local app="$2"
  local derived_data="$3"
  local embedded_key actual_key generate_keys
  embedded_key="$(delta_plist_value SUPublicEDKey "$app/Contents/Info.plist")"

  if [[ -n "${DELTA_SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    [[ -f "$DELTA_SPARKLE_PRIVATE_KEY_FILE" ]] \
      || delta_fail "Sparkle private key file is missing: $DELTA_SPARKLE_PRIVATE_KEY_FILE"
    actual_key="$(/usr/bin/xcrun swift "$root/Scripts/sparkle-public-key.swift" "$DELTA_SPARKLE_PRIVATE_KEY_FILE")" \
      || delta_fail 'unable to derive the Sparkle public key'
  else
    generate_keys="$(delta_resolve_sparkle_tool "$root" "$derived_data" generate_keys)"
    actual_key="$("$generate_keys" --account "${DELTA_SPARKLE_KEY_ACCOUNT:-com.delta.backup.sparkle}" -p 2>/dev/null)" \
      || delta_fail 'unable to read the Sparkle signing key from Keychain'
  fi
  [[ "$actual_key" == "$embedded_key" ]] \
    || delta_fail 'the Sparkle signing key does not match SUPublicEDKey embedded in Delta'
}
