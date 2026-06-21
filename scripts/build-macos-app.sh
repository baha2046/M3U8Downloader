#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/M3U8Downloader"
PROJECT_PATH="$PROJECT_DIR/M3U8Downloader.xcodeproj"

SCHEME="${SCHEME:-M3U8Downloader}"
CONFIGURATION="${CONFIGURATION:-Release}"
SDK="${SDK:-macosx}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/.build/macos}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$BUILD_ROOT/DerivedData}"
APP_NAME="${APP_NAME:-M3U8Downloader.app}"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "error: Xcode project not found at $PROJECT_PATH" >&2
  exit 1
fi

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild is required. Install Xcode from the App Store or Apple Developer." >&2
  exit 1
fi

mkdir -p "$BUILD_ROOT"

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build \
  "$@"

APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: expected app bundle was not created at $APP_PATH" >&2
  exit 1
fi

echo "Built app: $APP_PATH"
