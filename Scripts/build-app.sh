#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/Scripts/lib/delta-release.sh"

SIGNING_IDENTITY="${DELTA_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  "$ROOT_DIR/Scripts/build-release.sh"
  exit 0
fi
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  "$ROOT_DIR/Scripts/build-release.sh"
  exit 0
fi

# Reccy's CI build deliberately omits production signing. Delta additionally
# applies an ad-hoc seal because its acceptance evidence is bound to the app's
# CDHash. Without a stable team identity, Hardened Runtime library validation
# would reject Sparkle before launch, so it is disabled only for this explicitly
# non-shipping build. Developer ID archives always use build-release.sh instead.
DERIVED_DATA="${DELTA_DERIVED_DATA:-$(delta_default_derived_data CI)}"
OUTPUT_APP="$ROOT_DIR/dist/Delta.app"
HOST_ARCH="$(/usr/bin/uname -m)"

"$ROOT_DIR/Scripts/bootstrap-tools.sh"
"$ROOT_DIR/Scripts/verify-tools.sh"
"$ROOT_DIR/Scripts/build-icon.sh"

/usr/bin/xcodebuild \
  -quiet \
  -project "$ROOT_DIR/Delta.xcodeproj" \
  -scheme Delta \
  -configuration Release \
  -destination "platform=macOS,arch=$HOST_ARCH" \
  -derivedDataPath "$DERIVED_DATA" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- \
  DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO \
  build

BUILT_APP="$DERIVED_DATA/Build/Products/Release/Delta.app"
[[ -d "$BUILT_APP" ]] || delta_fail "Xcode did not produce $BUILT_APP"
/bin/rm -rf "$OUTPUT_APP"
/bin/mkdir -p "$(dirname "$OUTPUT_APP")"
/usr/bin/ditto "$BUILT_APP" "$OUTPUT_APP"
/usr/bin/codesign --verify --strict --deep --verbose=2 "$OUTPUT_APP" \
  || delta_fail 'the ad-hoc CI app failed strict signature verification'
DELTA_ENABLE_MENU_BAR_ACCEPTANCE=1 \
  "$OUTPUT_APP/Contents/MacOS/Delta" --acceptance-menu-bar-surface >/dev/null \
  || delta_fail 'the ad-hoc CI app failed to launch and load its embedded frameworks'

delta_note "Built certificate-free CI app at $OUTPUT_APP"
