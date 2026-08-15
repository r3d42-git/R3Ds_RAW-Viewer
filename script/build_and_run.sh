#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
CONFIGURATION="release"
if [[ "$MODE" == "--debug" || "$MODE" == "debug" ]]; then
  CONFIGURATION="debug"
fi
APP_NAME="RAW Viewer"
PROCESS_NAME="RAWViewer"
BUNDLE_ID="de.r3d.rawviewer"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="${RAW_VIEWER_VERSION:-0.6.2}"
BUILD_NUMBER="${RAW_VIEWER_BUILD_NUMBER:-12}"
SIGNING_IDENTITY="${RAW_VIEWER_SIGNING_IDENTITY:--}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$PROCESS_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Resources/AppIcon.icns"
MODULE_CACHE="$ROOT_DIR/.build/module-cache"
run_swift_build() {
  if [[ -n "${RAW_VIEWER_SWIFT_SCRATCH_PATH:-}" ]]; then
    swift build "$@" --disable-sandbox --scratch-path "$RAW_VIEWER_SWIFT_SCRATCH_PATH"
  else
    swift build "$@"
  fi
}

run_swift_test() {
  if [[ -n "${RAW_VIEWER_SWIFT_SCRATCH_PATH:-}" ]]; then
    swift test --disable-sandbox --scratch-path "$RAW_VIEWER_SWIFT_SCRATCH_PATH"
  else
    swift test
  fi
}

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: A complete Xcode installation must be selected with xcode-select." >&2
  echo "Current developer directory: $(xcode-select -p 2>/dev/null || echo unavailable)" >&2
  exit 1
fi

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE"

mkdir -p "$MODULE_CACHE"
pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true

run_swift_build -c "$CONFIGURATION"
BUILD_BINARY="$(run_swift_build -c "$CONFIGURATION" --show-bin-path)/$PROCESS_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ ! -f "$APP_ICON_SOURCE" ]]; then
  echo "error: Missing app icon: $APP_ICON_SOURCE" >&2
  exit 1
fi
cp "$APP_ICON_SOURCE" "$APP_RESOURCES/AppIcon.icns"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>de</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$PROCESS_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP_BUNDLE"
else
  codesign --force --sign "$SIGNING_IDENTITY" --options runtime --timestamp "$APP_BUNDLE"
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 2
    pgrep -x "$PROCESS_NAME" >/dev/null
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    ;;
  --build|build)
    codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    ;;
  --test|test)
    run_swift_test
    ;;
  *)
    echo "usage: $0 [run|--build|--test|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
