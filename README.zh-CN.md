# m3u8 下载器

[English](README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md)

下载 HLS `.m3u8` 流，在本地清理并准备媒体分片，然后使用 `ffmpeg`
打包为 `.mp4` 文件。

（与直接使用 ffmpeg 不同：支持带有伪图片头的 m3u8，并会清理带有无效前缀的分片。）

本仓库现在提供三种使用方式：

- `M3U8Downloader/` 中的原生 SwiftUI macOS 应用。
- `download_m3u8.py` 中的 Python 命令行下载器。
- `web_app.py` 中的小型本地 Flask 网页界面。

本下载器仅适用于你有权下载的流媒体内容。它不会绕过 DRM 或其他访问控制。

## 原生 macOS 应用

<p>
  <img src="https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square" alt="MIT Licence">
  <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-success?style=flat-square" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6">
  <img src="https://img.shields.io/badge/Liquid%20Glass-macOS%2026-7c6cff?style=flat-square" alt="Liquid Glass">
</p>

`M3U8Downloader` 是一个 macOS SwiftUI 应用，将下载流程包装为桌面界面。
它支持远程播放列表 URL 或本地 `.m3u8` 文件，下载并清理 HLS 分片，然后调用
`ffmpeg` 打包最终的 MP4。

![M3U8Downloader macOS app](docs/screen1.png)

### 应用功能

- 支持远程 URL 和本地 `.m3u8` 文件来源。
- 可选择输出文件名和保存文件夹。
- 自定义 HTTP 请求头，每行一个 `Name: Value`。
- 主播放列表的首选画质选择：Auto / Best、1080p 或 720p。
- 分片并发数、重试次数、超时和覆盖控制。
- 带搜索功能的下载队列侧边栏。
- 每个下载任务显示进度、分片数量、FFmpeg 日志，并支持重试、取消、在 Finder 中显示、
  打开视频等操作。
- 可在偏好设置中配置 `ffmpeg` 路径和默认下载文件夹。

### macOS 要求

- macOS 14 或更新版本。
- 安装带 macOS SDK 的 Xcode。
- 本地已安装 `ffmpeg`。

如果需要，可以使用 Homebrew 安装 `ffmpeg`：

```bash
brew install ffmpeg
```

应用会自动检测常见的 `ffmpeg` 位置：

- `/opt/homebrew/bin/ffmpeg`
- `/usr/local/bin/ffmpeg`
- `/usr/bin/ffmpeg`
- 来自 `PATH` 的 `ffmpeg`

你也可以在应用的偏好设置页面中手动覆盖路径。

### 构建应用

Xcode 项目已提交在：

```text
M3U8Downloader/M3U8Downloader.xcodeproj
```

从终端构建：

```bash
cd M3U8Downloader
./build.sh
```

脚本会以 Debug 配置构建 `M3U8Downloader` scheme，并将生成的 app bundle
移动到仓库根目录：

```text
M3U8Downloader.app
```

你也可以在 Xcode 中打开项目：

```bash
open M3U8Downloader/M3U8Downloader.xcodeproj
```

然后选择 `M3U8Downloader` scheme 并运行。

### 运行应用

构建完成后，从仓库根目录启动应用：

```bash
open ./M3U8Downloader.app
```

下载流媒体：

1. 选择 `Remote URL` 或 `Local .m3u8 File`。
2. 输入播放列表 URL，或浏览选择本地播放列表。
3. 选择输出文件名和保存文件夹。
4. 需要请求头、画质、并发数、重试次数或超时选项时，展开 Advanced Settings。
5. 点击 `Download Stream`。

完成的任务可以从任务详情页在 Finder 中打开，或直接播放视频。

### 重新生成 Xcode 项目

应用也包含一个 XcodeGen 配置：

```text
M3U8Downloader/project.yml
```

如果你更新了项目结构并希望重新生成 `.xcodeproj`，请安装 XcodeGen 后运行：

```bash
cd M3U8Downloader
xcodegen generate
```

## Python CLI

CLI 会逐个下载远程播放列表的分片，在检测到伪图片头时移除该头部，写入清理后的本地播放列表，
然后使用 `ffmpeg` 将本地播放列表合成为最终 MP4。

### CLI 要求

- Python 3。
- `ffmpeg` 可从 `PATH` 中访问。

### CLI 用法

下载远程播放列表：

```bash
python3 download_m3u8.py "https://cdn3.turboviplay.com/data1/685f4c3d5bc66/685f4c3d5bc66.m3u8"
```

默认情况下，MP4 会使用播放列表文件名保存到用户 Downloads 文件夹，例如
`/Users/ericchan/Downloads/`。

使用自定义输出文件名保存：

```bash
python3 download_m3u8.py "https://cdn3.turboviplay.com/data1/685f4c3d5bc66/685f4c3d5bc66.m3u8" -o sample.mp4
```

从本地 `.m3u8` 播放列表文件下载：

```bash
python3 download_m3u8.py ./video.m3u8 -o video.mp4
```

当流媒体需要请求头时传入 headers：

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" \
  --header "Referer: https://example.com" \
  --header "User-Agent: Mozilla/5.0" \
  -o video.mp4
```

避免覆盖已有文件：

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" -o video.mp4 --no-overwrite
```

当主播放列表提供 720p 或 1080p 时，优先选择指定画质：

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" --quality 1080p -o video.mp4
```

调整分片下载参数：

```bash
python3 download_m3u8.py "https://example.com/video.m3u8" \
  --segment-workers 12 \
  --retries 4 \
  --timeout 20 \
  -o video.mp4
```

分片会并发下载，超时失败会自动重试。

## 本地 Web UI

安装 UI 依赖：

```bash
python3 -m pip install -r requirements.txt
```

启动本地服务器：

```bash
python3 web_app.py
```

在浏览器中打开 `http://127.0.0.1:5000`。该界面可以从远程 m3u8 URL 或上传的本地
`.m3u8` 文件加入下载队列，设置与 CLI 相同的选项，查看实时日志，查看本地保存路径，
并通过浏览器下载已完成的 MP4。

Web 应用仅用于本地使用，并绑定到 `127.0.0.1`。

## 测试

使用仓库中的虚拟环境运行测试：

```bash
./.venv/bin/python3 -m pytest
```

## 许可证

m3u8Downloader 基于 MIT License 发布。详情请见 [LICENSE](LICENSE)。
