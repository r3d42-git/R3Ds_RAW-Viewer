#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./script/release.sh VERSION

Build, Developer ID sign, notarize, staple, package, and verify a local release.
VERSION must use the form X.Y.Z, for example 0.6.2.

Optional environment overrides:
  MACOS_SIGNING_IDENTITY  Developer ID Application identity
  MACOS_NOTARY_PROFILE    notarytool Keychain profile
  RELEASE_OUTPUT_DIR      artifact directory (defaults to dist)
  RELEASE_ALLOW_DIRTY=1   allow a dirty Git worktree (testing only)
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

[[ $# -eq 1 ]] || { usage >&2; exit 64; }
[[ "$1" != "-h" && "$1" != "--help" ]] || { usage; exit 0; }

VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must use X.Y.Z"

APP_NAME="RAW Viewer"
PROCESS_NAME="RAWViewer"
BUNDLE_ID="de.r3d.rawviewer"
ARCHITECTURE="$(uname -m)"
[[ "$ARCHITECTURE" == "arm64" ]] || die "only arm64 release artifacts are currently supported"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$PROCESS_NAME"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
FINAL_ZIP="$OUTPUT_DIR/RAW-Viewer-$VERSION-macOS-$ARCHITECTURE.zip"
CHECKSUM_FILE="$FINAL_ZIP.sha256"
NOTARY_DIR="$OUTPUT_DIR/notary"
SUBMISSION_ZIP="$NOTARY_DIR/RAW-Viewer-$VERSION-macOS-$ARCHITECTURE-submitted.zip"
NOTARY_RESULT="$NOTARY_DIR/RAW-Viewer-$VERSION-notary-result.json"
NOTARY_LOG="$NOTARY_DIR/RAW-Viewer-$VERSION-notary-log.json"
# Fingerprint selects G2 when Developer ID certificates share a name.
SIGNING_IDENTITY="${MACOS_SIGNING_IDENTITY:-D548540E7FE1BD9B3C4518CC02D8786E1BFEB885}"
NOTARY_PROFILE="${MACOS_NOTARY_PROFILE:-RAW-Viewer-notary}"

for command_name in codesign security xcrun ditto unzip shasum spctl plutil file; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done

if [[ "${RELEASE_ALLOW_DIRTY:-0}" != "1" ]]; then
  [[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]] || \
    die "Git worktree is not clean; commit or stash changes before a release"
fi

security find-identity -v -p codesigning | grep -F "$SIGNING_IDENTITY" >/dev/null || \
  die "Developer ID signing identity is unavailable: $SIGNING_IDENTITY"

"$ROOT_DIR/script/verify_license_material.sh" "$ROOT_DIR"

echo "==> Testing Swift package"
(cd "$ROOT_DIR" && ./script/build_and_run.sh --test)

echo "==> Building and signing optimized $ARCHITECTURE app"
(cd "$ROOT_DIR" && RAW_VIEWER_VERSION="$VERSION" RAW_VIEWER_SIGNING_IDENTITY="$SIGNING_IDENTITY" ./script/build_and_run.sh --build)

[[ -x "$APP_BINARY" ]] || die "release executable not found: $APP_BINARY"
"$ROOT_DIR/script/verify_license_material.sh" "$APP_BUNDLE/Contents/Resources"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")" == "$BUNDLE_ID" ]] || \
  die "app bundle identifier does not match $BUNDLE_ID"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")" == "$VERSION" ]] || \
  die "app version does not match $VERSION"
file "$APP_BINARY" | grep -F "arm64" >/dev/null || die "release executable is not arm64"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
codesign -dv --verbose=4 "$APP_BUNDLE"

mkdir -p "$OUTPUT_DIR" "$NOTARY_DIR"
rm -f "$FINAL_ZIP" "$CHECKSUM_FILE" "$SUBMISSION_ZIP" "$NOTARY_RESULT" "$NOTARY_LOG"

echo "==> Creating notarization submission"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SUBMISSION_ZIP"
unzip -t "$SUBMISSION_ZIP" >/dev/null

echo "==> Submitting to Apple Notary Service"
set +e
xcrun notarytool submit "$SUBMISSION_ZIP" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait \
  --timeout 30m \
  --output-format json >"$NOTARY_RESULT"
NOTARY_EXIT=$?
set -e

cat "$NOTARY_RESULT"
SUBMISSION_ID="$(plutil -extract id raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"
NOTARY_STATUS="$(plutil -extract status raw -o - "$NOTARY_RESULT" 2>/dev/null || true)"

if [[ -n "$SUBMISSION_ID" ]]; then
  xcrun notarytool log "$SUBMISSION_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$NOTARY_LOG" || true
fi

[[ $NOTARY_EXIT -eq 0 && "$NOTARY_STATUS" == "Accepted" ]] || \
  die "notarization failed with status '${NOTARY_STATUS:-unknown}'; inspect $NOTARY_LOG"

echo "==> Stapling notarization ticket"
xcrun stapler staple "$APP_BUNDLE"
xcrun stapler validate "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose=4 "$APP_BUNDLE"

echo "==> Creating final distribution archive"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$FINAL_ZIP"
unzip -t "$FINAL_ZIP" >/dev/null

VERIFY_DIR="$(mktemp -d /private/tmp/raw-viewer-release-verify.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$FINAL_ZIP" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/$APP_NAME.app"
"$ROOT_DIR/script/verify_license_material.sh" "$EXTRACTED_APP/Contents/Resources"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$EXTRACTED_APP/Contents/Info.plist")" == "$VERSION" ]] || \
  die "extracted app version does not match $VERSION"
file "$EXTRACTED_APP/Contents/MacOS/$PROCESS_NAME" | grep -F "arm64" >/dev/null || \
  die "extracted app executable is not arm64"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
codesign -dv --verbose=4 "$EXTRACTED_APP"
xcrun stapler validate "$EXTRACTED_APP"
spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"

(cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$FINAL_ZIP")") | tee "$CHECKSUM_FILE"

echo
echo "Release artifact ready: $FINAL_ZIP"
echo "Notary submission: $SUBMISSION_ID"
echo "Checksum file: $CHECKSUM_FILE"
echo "Nothing was uploaded to GitHub. Publish separately after review."
