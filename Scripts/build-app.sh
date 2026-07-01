#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Delta"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
FRAMEWORKS="$CONTENTS/Frameworks"
LAUNCH_AGENTS="$CONTENTS/Library/LaunchAgents"
TOOLS_DIR="$ROOT_DIR/Resources/Tools/bin"
SIGN_IDENTITY="${DELTA_CODESIGN_IDENTITY:-}"

if [[ ! -x "$TOOLS_DIR/restic" || ! -x "$TOOLS_DIR/rclone" ]]; then
  "$ROOT_DIR/Scripts/bootstrap-tools.sh"
fi
"$ROOT_DIR/Scripts/verify-tools.sh"
"$ROOT_DIR/Scripts/build-icon.sh"

/usr/bin/swift build -c "$CONFIGURATION" --product Delta
/usr/bin/swift build -c "$CONFIGURATION" --product DeltaAgent
/usr/bin/swift build -c "$CONFIGURATION" --product DeltaSecretBridge
SWIFT_BUILD_DIR="$(/usr/bin/swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS" "$RESOURCES/Tools" "$FRAMEWORKS" "$LAUNCH_AGENTS"

/bin/cp "$SWIFT_BUILD_DIR/Delta" "$MACOS/Delta"
/bin/cp "$SWIFT_BUILD_DIR/DeltaAgent" "$MACOS/DeltaAgent"
/bin/cp "$SWIFT_BUILD_DIR/DeltaSecretBridge" "$MACOS/DeltaSecretBridge"
/bin/cp "$TOOLS_DIR/restic" "$MACOS/restic"
/bin/cp "$TOOLS_DIR/rclone" "$MACOS/rclone"
/bin/cp "$ROOT_DIR/Resources/AppIcon/Delta.icns" "$RESOURCES/Delta.icns"
/bin/cp "$ROOT_DIR/Packaging/Delta.app.plist" "$CONTENTS/Info.plist"
/bin/cp "$ROOT_DIR/Packaging/com.delta.backup.agent.plist" "$LAUNCH_AGENTS/com.delta.backup.agent.plist"
/bin/echo -n "APPL????" > "$CONTENTS/PkgInfo"

SPARKLE_FRAMEWORK_SOURCE="$SWIFT_BUILD_DIR/Sparkle.framework"
if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  SPARKLE_FRAMEWORK_SOURCE="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle.framework' -type d | head -n 1)"
fi
if [[ -z "$SPARKLE_FRAMEWORK_SOURCE" || ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  printf "Sparkle.framework was not found. Run swift build --product Delta first.\n" >&2
  exit 1
fi
/usr/bin/ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS/Sparkle.framework"

/bin/chmod 755 "$MACOS/Delta" "$MACOS/DeltaAgent" "$MACOS/DeltaSecretBridge" "$MACOS/restic" "$MACOS/rclone"

if ! /usr/bin/otool -l "$MACOS/Delta" | /usr/bin/grep -q "@executable_path/../Frameworks"; then
  /usr/bin/install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS/Delta"
fi

sign_sparkle_framework() {
  local identity="$1"
  local timestamp_flag="$2"
  local sparkle="$FRAMEWORKS/Sparkle.framework"
  local version_dir="$sparkle/Versions/B"

  if [[ -d "$version_dir/XPCServices/Installer.xpc" ]]; then
    /usr/bin/codesign --force --options runtime $timestamp_flag --sign "$identity" "$version_dir/XPCServices/Installer.xpc"
  fi
  if [[ -d "$version_dir/XPCServices/Downloader.xpc" ]]; then
    /usr/bin/codesign --force --options runtime $timestamp_flag --preserve-metadata=entitlements --sign "$identity" "$version_dir/XPCServices/Downloader.xpc"
  fi
  if [[ -x "$version_dir/Autoupdate" ]]; then
    /usr/bin/codesign --force --options runtime $timestamp_flag --sign "$identity" "$version_dir/Autoupdate"
  fi
  if [[ -d "$version_dir/Updater.app" ]]; then
    /usr/bin/codesign --force --options runtime $timestamp_flag --sign "$identity" "$version_dir/Updater.app"
  fi
  /usr/bin/codesign --force --options runtime $timestamp_flag --sign "$identity" "$sparkle"
}

if [[ -n "$SIGN_IDENTITY" ]]; then
  sign_sparkle_framework "$SIGN_IDENTITY" "--timestamp"
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$ROOT_DIR/Packaging/Delta.entitlements" --sign "$SIGN_IDENTITY" "$MACOS/restic"
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$ROOT_DIR/Packaging/Delta.entitlements" --sign "$SIGN_IDENTITY" "$MACOS/rclone"
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$ROOT_DIR/Packaging/Delta.entitlements" --sign "$SIGN_IDENTITY" "$MACOS/DeltaSecretBridge"
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$ROOT_DIR/Packaging/Delta.entitlements" --sign "$SIGN_IDENTITY" "$MACOS/DeltaAgent"
  /usr/bin/codesign --force --options runtime --timestamp --entitlements "$ROOT_DIR/Packaging/Delta.entitlements" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  /usr/bin/codesign --verify --strict --deep --verbose=2 "$APP_BUNDLE"
else
  sign_sparkle_framework "-" ""
  /usr/bin/codesign --force --sign - "$MACOS/restic"
  /usr/bin/codesign --force --sign - "$MACOS/rclone"
  /usr/bin/codesign --force --sign - "$MACOS/DeltaSecretBridge"
  /usr/bin/codesign --force --sign - "$MACOS/DeltaAgent"
  /usr/bin/codesign --force --sign - "$APP_BUNDLE"
fi

printf "Built %s\n" "$APP_BUNDLE"
