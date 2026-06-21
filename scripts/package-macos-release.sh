#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/package-macos-release.sh [--format zip|dmg] [--configuration Release]

Environment:
  VERSION              Version string used in the artifact name. Defaults to git describe output.
  CODESIGN_IDENTITY    Optional signing identity for the staged app bundle.
                       Example: CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
USAGE
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-macos-app.sh"

FORMAT="zip"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-M3U8Downloader.app}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --format)
      FORMAT="${2:-}"
      shift 2
      ;;
    --configuration)
      CONFIGURATION="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$FORMAT" in
  zip|dmg) ;;
  *)
    echo "error: --format must be 'zip' or 'dmg'" >&2
    exit 1
    ;;
esac

if [[ -z "$CONFIGURATION" ]]; then
  echo "error: --configuration cannot be empty" >&2
  exit 1
fi

if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(git -C "$ROOT_DIR" describe --tags --always --dirty 2>/dev/null || date +%Y%m%d%H%M%S)"
fi

VERSION_SLUG="$(printf '%s' "$VERSION" | tr -c 'A-Za-z0-9._-' '-')"
ARTIFACT_BASENAME="M3U8Downloader-${VERSION_SLUG}-macOS"
BUILD_ROOT="$ROOT_DIR/.build/macos"
DERIVED_DATA_PATH="$BUILD_ROOT/DerivedData"
RELEASE_ROOT="$ROOT_DIR/.build/release"
STAGING_DIR="$RELEASE_ROOT/$ARTIFACT_BASENAME"
DIST_DIR="$ROOT_DIR/dist"

export CONFIGURATION
export BUILD_ROOT
export DERIVED_DATA_PATH

"$BUILD_SCRIPT"

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"
STAGED_APP="$STAGING_DIR/$APP_NAME"

if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
ditto "$BUILT_APP" "$STAGED_APP"

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$STAGED_APP"
fi

case "$FORMAT" in
  zip)
    ARTIFACT_PATH="$DIST_DIR/$ARTIFACT_BASENAME.zip"
    rm -f "$ARTIFACT_PATH"
    (
      cd "$STAGING_DIR"
      ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ARTIFACT_PATH"
    )
    ;;
  dmg)
    ARTIFACT_PATH="$DIST_DIR/$ARTIFACT_BASENAME.dmg"
    rm -f "$ARTIFACT_PATH"
    hdiutil create \
      -volname "M3U8Downloader" \
      -srcfolder "$STAGING_DIR" \
      -ov \
      -format UDZO \
      "$ARTIFACT_PATH"
    ;;
esac

echo "Release artifact: $ARTIFACT_PATH"
