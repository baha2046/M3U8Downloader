#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/package-macos-release.sh [--format zip|dmg] [--configuration Release]

Environment:
  VERSION              Version string used in the artifact name. Defaults to git describe output.
  CODESIGN_IDENTITY    Signing identity for the staged app bundle. Defaults to the
                       first valid Developer ID Application identity in the keychain.
                       Example: CODESIGN_IDENTITY="Developer ID Application: Example (TEAMID)"
  NOTARYTOOL_PROFILE   Keychain profile created by `xcrun notarytool store-credentials`.
  SKIP_CODESIGN        Set to 1 to create an unsigned local package.
  SKIP_NOTARIZATION    Set to 1 for a signed local package without notarization.
USAGE
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$ROOT_DIR/scripts/build-macos-app.sh"

FORMAT="zip"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_NAME="${APP_NAME:-M3U8Downloader.app}"

find_developer_id_application_identity() {
  if ! command -v security >/dev/null 2>&1; then
    return 1
  fi

  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F '"' '/"Developer ID Application:/ { print $2; exit }'
}

create_artifact() {
  case "$FORMAT" in
    zip)
      rm -f "$ARTIFACT_PATH"
      (
        cd "$STAGING_DIR"
        ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP_NAME" "$ARTIFACT_PATH"
      )
      ;;
    dmg)
      rm -f "$ARTIFACT_PATH"
      hdiutil create \
        -volname "M3U8Downloader" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$ARTIFACT_PATH"
      ;;
  esac
}

submit_for_notarization() {
  if ! xcrun notarytool submit \
    "$ARTIFACT_PATH" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --wait; then
    echo "error: Apple notarization failed for $ARTIFACT_PATH" >&2
    exit 1
  fi
}

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
ditto --norsrc --noextattr --noqtn "$BUILT_APP" "$STAGED_APP"
xattr -cr "$STAGED_APP"

if [[ "${SKIP_CODESIGN:-0}" != "1" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    CODESIGN_IDENTITY="$(find_developer_id_application_identity || true)"
  fi

  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "error: no Developer ID Application signing identity was found." >&2
    echo "Set CODESIGN_IDENTITY or SKIP_CODESIGN=1 for an unsigned local package." >&2
    exit 1
  fi

  codesign --force --deep --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$STAGED_APP"
  codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

  if [[ "${SKIP_NOTARIZATION:-0}" != "1" && -z "${NOTARYTOOL_PROFILE:-}" ]]; then
    echo "error: NOTARYTOOL_PROFILE is required for a notarized release." >&2
    echo "Create one with 'xcrun notarytool store-credentials' or set SKIP_NOTARIZATION=1." >&2
    exit 1
  fi
fi

case "$FORMAT" in
  zip)
    ARTIFACT_PATH="$DIST_DIR/$ARTIFACT_BASENAME.zip"
    ;;
  dmg)
    ARTIFACT_PATH="$DIST_DIR/$ARTIFACT_BASENAME.dmg"
    ;;
esac

create_artifact

if [[ "${SKIP_CODESIGN:-0}" != "1" && "${SKIP_NOTARIZATION:-0}" != "1" ]]; then
  submit_for_notarization

  if [[ "$FORMAT" == "zip" ]]; then
    STAPLE_TARGET="$STAGED_APP"
  else
    STAPLE_TARGET="$ARTIFACT_PATH"
  fi

  if ! xcrun stapler staple "$STAPLE_TARGET"; then
    echo "error: failed to staple notarization ticket to $STAPLE_TARGET" >&2
    exit 1
  fi

  if ! xcrun stapler validate "$STAPLE_TARGET"; then
    echo "error: failed to validate notarization ticket on $STAPLE_TARGET" >&2
    exit 1
  fi

  if [[ "$FORMAT" == "zip" ]]; then
    create_artifact
  fi
fi

echo "Release artifact: $ARTIFACT_PATH"
