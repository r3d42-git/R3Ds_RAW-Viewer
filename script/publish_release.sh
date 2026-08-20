#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ./script/publish_release.sh [--dry-run] VERSION [RELEASE_NOTES_FILE]

Publish an already signed, notarized, stapled, and verified local artifact.
This command creates/pushes the version tag and publishes a GitHub release.

Use --dry-run to validate the local artifact without changing Git or GitHub.
Optional environment override: RELEASE_OUTPUT_DIR (defaults to dist).
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

DRY_RUN=0
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
fi
[[ "${1:-}" != "-h" && "${1:-}" != "--help" ]] || { usage; exit 0; }
[[ $# -ge 1 && $# -le 2 ]] || { usage >&2; exit 64; }

VERSION="$1"
NOTES_FILE="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must use X.Y.Z"
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || die "release notes file not found: $NOTES_FILE"

APP_NAME="RAW Viewer"
PROCESS_NAME="RAWViewer"
ARCHITECTURE="arm64"
TAG="v$VERSION"
REPOSITORY="${GITHUB_REPOSITORY:-r3d42-git/R3Ds_RAW-Viewer}"
RELEASE_BRANCH="${RELEASE_BRANCH:-main}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
ARTIFACT="$OUTPUT_DIR/RAW-Viewer-$VERSION-macOS-$ARCHITECTURE.zip"
CHECKSUM_FILE="$ARTIFACT.sha256"

for command_name in git gh unzip shasum ditto codesign spctl xcrun plutil file; do
  command -v "$command_name" >/dev/null 2>&1 || die "missing required command: $command_name"
done

[[ -f "$ARTIFACT" ]] || die "release artifact not found: $ARTIFACT"
[[ -f "$CHECKSUM_FILE" ]] || die "checksum file not found: $CHECKSUM_FILE"
[[ -z "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]] || \
  die "Git worktree is not clean; commit or stash changes before publishing"

CURRENT_BRANCH="$(git -C "$ROOT_DIR" symbolic-ref --short HEAD)"
[[ "$CURRENT_BRANCH" == "$RELEASE_BRANCH" ]] || \
  die "publishing is restricted to branch '$RELEASE_BRANCH' (current: '$CURRENT_BRANCH')"

EXPECTED_SHA="$(awk 'NR == 1 { print $1 }' "$CHECKSUM_FILE")"
ACTUAL_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{ print $1 }')"
[[ -n "$EXPECTED_SHA" && "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || die "artifact checksum mismatch"
unzip -t "$ARTIFACT" >/dev/null

VERIFY_DIR="$(mktemp -d /private/tmp/raw-viewer-publish-verify.XXXXXX)"
PUBLISH_NOTES="$(mktemp /private/tmp/raw-viewer-release-notes.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"; rm -f "$PUBLISH_NOTES"' EXIT
ditto -x -k "$ARTIFACT" "$VERIFY_DIR"
EXTRACTED_APP="$VERIFY_DIR/$APP_NAME.app"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$EXTRACTED_APP/Contents/Info.plist")" == "$VERSION" ]] || \
  die "app version does not match $VERSION"
file "$EXTRACTED_APP/Contents/MacOS/$PROCESS_NAME" | grep -F "arm64" >/dev/null || \
  die "app executable is not arm64"
codesign --verify --deep --strict --verbose=2 "$EXTRACTED_APP"
xcrun stapler validate "$EXTRACTED_APP"
spctl --assess --type execute --verbose=4 "$EXTRACTED_APP"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run passed."
  echo "Would publish $TAG from $(git -C "$ROOT_DIR" rev-parse HEAD)"
  echo "Artifact: $ARTIFACT"
  echo "SHA-256: $ACTUAL_SHA"
  exit 0
fi

if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  [[ "$(git -C "$ROOT_DIR" rev-parse "$TAG^{}")" == "$(git -C "$ROOT_DIR" rev-parse HEAD)" ]] || \
    die "local tag $TAG does not point to HEAD"
else
  git -C "$ROOT_DIR" tag -a "$TAG" -m "RAW Viewer $VERSION"
fi

echo "==> Pushing $RELEASE_BRANCH and $TAG"
git -C "$ROOT_DIR" push origin "$RELEASE_BRANCH"
git -C "$ROOT_DIR" push origin "$TAG"

VERIFICATION_NOTES="## Release verification

- Developer ID signed with Hardened Runtime and a secure timestamp.
- Accepted by the Apple Notary Service and distributed with a stapled ticket.
- The final ZIP passed archive, strict code-signature, stapler, and Gatekeeper checks.

SHA-256: \`$ACTUAL_SHA\`"

if [[ -n "$NOTES_FILE" ]]; then
  cp "$NOTES_FILE" "$PUBLISH_NOTES"
  printf '\n\n%s\n' "$VERIFICATION_NOTES" >>"$PUBLISH_NOTES"
  gh release create "$TAG" "$ARTIFACT" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --fail-on-no-commits \
    --latest \
    --title "RAW Viewer $VERSION" \
    --notes-file "$PUBLISH_NOTES"
else
  gh release create "$TAG" "$ARTIFACT" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --fail-on-no-commits \
    --latest \
    --title "RAW Viewer $VERSION" \
    --generate-notes \
    --notes "$VERIFICATION_NOTES"
fi

echo "==> Downloading published asset for independent verification"
PUBLISHED_DIR="$VERIFY_DIR/published"
mkdir -p "$PUBLISHED_DIR"
gh release download "$TAG" \
  --repo "$REPOSITORY" \
  --pattern "$(basename "$ARTIFACT")" \
  --dir "$PUBLISHED_DIR"
PUBLISHED_ARTIFACT="$PUBLISHED_DIR/$(basename "$ARTIFACT")"
cmp -s "$ARTIFACT" "$PUBLISHED_ARTIFACT" || die "published asset differs from local artifact"

PUBLISHED_SHA="$(shasum -a 256 "$PUBLISHED_ARTIFACT" | awk '{ print $1 }')"
GITHUB_DIGEST="$(gh release view "$TAG" --repo "$REPOSITORY" --json assets --jq ".assets[] | select(.name == \"$(basename "$ARTIFACT")\") | .digest")"
[[ "$GITHUB_DIGEST" == "sha256:$PUBLISHED_SHA" ]] || die "GitHub digest mismatch"

PUBLISHED_EXTRACT="$PUBLISHED_DIR/extracted"
mkdir -p "$PUBLISHED_EXTRACT"
ditto -x -k "$PUBLISHED_ARTIFACT" "$PUBLISHED_EXTRACT"
PUBLISHED_APP="$PUBLISHED_EXTRACT/$APP_NAME.app"
[[ "$(plutil -extract CFBundleShortVersionString raw -o - "$PUBLISHED_APP/Contents/Info.plist")" == "$VERSION" ]] || \
  die "published app version does not match $VERSION"
codesign --verify --deep --strict --verbose=2 "$PUBLISHED_APP"
xcrun stapler validate "$PUBLISHED_APP"
spctl --assess --type execute --verbose=4 "$PUBLISHED_APP"

RELEASE_URL="$(gh release view "$TAG" --repo "$REPOSITORY" --json url --jq .url)"
echo "Published and verified: $RELEASE_URL"
echo "SHA-256: $PUBLISHED_SHA"
