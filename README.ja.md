# m3u8 ダウンローダー

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

HLS の `.m3u8` ストリームをダウンロードし、メディアセグメントをローカルで整理してから、
`ffmpeg` で `.mp4` としてパッケージ化します。

（ffmpeg 単体との違い：偽の画像ヘッダーを持つ m3u8 に対応し、無効なプレフィックスを持つ
セグメントをクリーンアップします。）

このリポジトリには、ダウンローダーを使うための 3 つの方法が含まれています。

- `M3U8Downloader/` にあるネイティブ SwiftUI macOS アプリ。
- `download_m3u8.py` にある Python コマンドラインダウンローダー。
- `web_app.py` にある小さなローカル Flask Web UI。

このダウンローダーは、ダウンロードする権利があるストリーム向けです。DRM やその他のアクセス制御を
回避するものではありません。

## ネイティブ macOS アプリ

<p>
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" alt="MIT Licence">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-success?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Liquid%20Glass-macOS%2026-7c6cff?style=flat-square" alt="Liquid Glass">
</p>

`M3U8Downloader` は、ダウンロード処理をデスクトップ UI で扱えるようにした macOS 向け
SwiftUI アプリです。リモートのプレイリスト URL またはローカルの `.m3u8` ファイルを受け取り、
HLS セグメントをダウンロードして整理し、`ffmpeg` を呼び出して最終的な MP4 を作成します。

![M3U8Downloader macOS app](docs/screen1.png)

### アプリの機能

- リモート URL とローカル `.m3u8` ファイルの入力に対応。
- 出力ファイル名と保存先フォルダの選択。
- カスタム HTTP ヘッダー。1 行につき 1 つの `Name: Value` ヘッダーを指定。
- マスタープレイリストの優先画質選択：Auto / Best、1080p、720p。
- セグメントワーカー数、リトライ、タイムアウト、上書きの制御。
- 検索付きのダウンロードキューサイドバー。
- 各ダウンロードの進捗、セグメント数、FFmpeg ログ、リトライ、キャンセル、Finder で表示、
  動画を開く操作。
- `ffmpeg` パスと既定のダウンロードフォルダを設定する環境設定。

### macOS 要件

- macOS 14 以降。
- macOS SDK を含む Xcode。
- ローカルにインストールされた `ffmpeg`。

必要に応じて Homebrew で `ffmpeg` をインストールします。

```bash
brew install ffmpeg
```

アプリは一般的な `ffmpeg` の場所を自動検出します。

- `/opt/homebrew/bin/ffmpeg`
- `/usr/local/bin/ffmpeg`
- `/usr/bin/ffmpeg`
- `PATH` 上の `ffmpeg`

アプリの環境設定画面でパスを上書きすることもできます。

### アプリのビルド

Xcode プロジェクトは次の場所にあります。

```text
M3U8Downloader/M3U8Downloader.xcodeproj
```

ターミナルからビルドします。

```bash
cd M3U8Downloader
./build.sh
```

このスクリプトは `M3U8Downloader` scheme を Debug 構成でビルドし、生成された app bundle を
リポジトリルートへ移動します。

```text
M3U8Downloader.app
```

Xcode でプロジェクトを開くこともできます。

```bash
open M3U8Downloader/M3U8Downloader.xcodeproj
```

その後、`M3U8Downloader` scheme を選択して実行します。

### アプリの実行

ビルド後、リポジトリルートからアプリを起動します。

```bash
open ./M3U8Downloader.app
```

ストリームをダウンロードする手順：

1. `Remote URL` または `Local .m3u8 File` を選択します。
2. プレイリスト URL を入力するか、ローカルプレイリストを選択します。
3. 出力ファイル名と保存先フォルダを選択します。
4. ヘッダー、画質、ワーカー数、リトライ、タイムアウトを設定する場合は Advanced Settings を開きます。
5. `Download Stream` をクリックします。

完了したジョブは、詳細画面から Finder で開くか、そのまま再生できます。

### Xcode プロジェクトの再生成

アプリには XcodeGen の設定も含まれています。

```text
M3U8Downloader/project.yml
```

プロジェクト構造を更新し、`.xcodeproj` を再生成したい場合は、XcodeGen をインストールして実行します。

```bash
cd M3U8Downloader
xcodegen generate
```

## Python CLI

CLI はリモートプレイリストのセグメントを順番にダウンロードし、偽の画像ヘッダーがある場合は
小さなヘッダーを削除し、整理済みのローカルプレイリストを書き出してから、`ffmpeg` で最終的な
MP4 に結合します。

### CLI 要件

- Python 3。
- `PATH` から利用できる `ffmpeg`。

### CLI の使い方

リモートプレイリストをダウンロードします。

```bash
python3 download_m3u8.py "https://cdn3.turboviplay.com/data1/685f4c3d5bc66/685f4c3d5bc66.m3u8"
```

既定では、MP4 はプレイリストのファイル名を使って、たとえば
`/Users/ericchan/Downloads/` のようなユーザーの Downloads フォルダに保存されます。

カスタム出力ファイル名で保存します。

```bash
python3 download_m3u8.py "https://cdn3.turboviplay.com/data1/685f4c3d5bc66/685f4c3d5bc66.m3u8" -o sample.mp4
```

ローカルの `.m3u8` プレイリストファイルからダウンロードします。

```bash
python3 download_m3u8.py ./video.m3u8 -o video.mp4
```

ストリームにヘッダーが必要な場合は指定します。

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" \
  --header "Referer: https://example.com" \
  --header "User-Agent: Mozilla/5.0" \
  -o video.mp4
```

既存ファイルの上書きを避けます。

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" -o video.mp4 --no-overwrite
```

マスタープレイリストに 720p または 1080p がある場合、優先画質を指定します。

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" --quality 1080p -o video.mp4
```

セグメントダウンロードを調整します。

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" \
  --segment-workers 12 \
  --retries 4 \
  --timeout 20 \
  -o video.mp4
```

セグメントは並列でダウンロードされ、タイムアウトした失敗はリトライされます。

## ローカル Web UI

UI の依存関係をインストールします。

```bash
python3 -m pip install -r requirements.txt
```

ローカルサーバーを起動します。

```bash
python3 web_app.py
```

ブラウザで `http://127.0.0.1:5000` を開きます。この UI では、リモート m3u8 URL または
アップロードしたローカル `.m3u8` ファイルからダウンロードをキューに入れ、CLI と同じオプションを設定し、
ライブログを確認し、ローカル保存パスを確認し、完了した MP4 をブラウザからダウンロードできます。

Web アプリはローカル利用を想定しており、`127.0.0.1` にバインドします。

## テスト

リポジトリの仮想環境を使ってテストを実行します。

```bash
./.venv/bin/python3 -m pytest
```

## ライセンス

m3u8Downloader は MIT License の下で公開されています。詳しくは [LICENSE](LICENSE) を参照してください。
