#!/bin/bash
set -e

# このスクリプトのあるディレクトリへ移動
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DERIVED_DATA="$SCRIPT_DIR/build"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project M3U8Downloader.xcodeproj \
           -scheme M3U8Downloader \
           -configuration Debug \
           -sdk macosx \
           -derivedDataPath "$DERIVED_DATA" \
           build

# ビルドされた .app をこのディレクトリへ移動
APP_PATH="$(find "$DERIVED_DATA/Build/Products" -maxdepth 2 -name '*.app' -type d | head -n 1)"
if [ -n "$APP_PATH" ]; then
    APP_NAME="$(basename "$APP_PATH")"
    rm -rf "$SCRIPT_DIR/../$APP_NAME"
    mv "$APP_PATH" "$SCRIPT_DIR/../$APP_NAME"
    echo "ビルド結果を移動しました: $SCRIPT_DIR/../$APP_NAME"
else
    echo "エラー: ビルドされた .app が見つかりませんでした" >&2
    exit 1
fi
