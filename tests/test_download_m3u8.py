import unittest
import tempfile
from unittest import mock
from urllib.error import URLError

import download_m3u8


class DownloadM3u8Tests(unittest.TestCase):
    def test_default_output_filename_uses_m3u8_basename(self):
        url = "https://cdn3.turboviplay.com/data1/685f4c3d5bc66/685f4c3d5bc66.m3u8"

        self.assertEqual(
            download_m3u8.default_output_path(url),
            download_m3u8.os.path.join(
                download_m3u8.os.path.expanduser("~/Downloads"),
                "685f4c3d5bc66.mp4",
            ),
        )

    def test_default_output_filename_falls_back_when_basename_is_not_usable(self):
        self.assertEqual(
            download_m3u8.default_output_path("https://example.com/"),
            download_m3u8.os.path.join(
                download_m3u8.DEFAULT_DOWNLOAD_DIR,
                "download.mp4",
            ),
        )

    def test_default_output_filename_uses_local_playlist_basename(self):
        self.assertEqual(
            download_m3u8.default_output_path("/tmp/local-playlist.m3u8"),
            download_m3u8.os.path.join(
                download_m3u8.DEFAULT_DOWNLOAD_DIR,
                "local-playlist.mp4",
            ),
        )

    def test_normalize_output_path_appends_mp4_extension(self):
        self.assertEqual(download_m3u8.normalize_output_path("movie"), "movie.mp4")

    def test_normalize_output_path_keeps_existing_mp4_extension(self):
        self.assertEqual(download_m3u8.normalize_output_path("movie.mp4"), "movie.mp4")

    def test_format_headers_accepts_one_or_more_header_values(self):
        headers = [
            "Referer: https://example.com",
            "User-Agent: Test Browser",
        ]

        self.assertEqual(
            download_m3u8.format_headers(headers),
            "Referer: https://example.com\r\nUser-Agent: Test Browser\r\n",
        )

    def test_format_headers_returns_none_without_headers(self):
        self.assertIsNone(download_m3u8.format_headers(None))
        self.assertIsNone(download_m3u8.format_headers([]))

    def test_validate_url_rejects_non_http_urls(self):
        with self.assertRaisesRegex(ValueError, "URL must start with http:// or https://"):
            download_m3u8.validate_url("file:///tmp/video.m3u8")

    def test_validate_source_accepts_existing_local_m3u8_file(self):
        with tempfile.NamedTemporaryFile(suffix=".m3u8") as playlist:
            self.assertEqual(download_m3u8.validate_source(playlist.name), playlist.name)

    def test_validate_source_rejects_missing_local_m3u8_file(self):
        with self.assertRaisesRegex(ValueError, "Local m3u8 file was not found"):
            download_m3u8.validate_source("/tmp/missing-video.m3u8")

    def test_find_ffmpeg_fails_clearly_when_missing(self):
        with mock.patch("download_m3u8.shutil.which", return_value=None):
            with self.assertRaisesRegex(RuntimeError, "ffmpeg was not found"):
                download_m3u8.find_ffmpeg()

    def test_build_ffmpeg_command_uses_overwrite_by_default_and_headers(self):
        command = download_m3u8.build_ffmpeg_command(
            ffmpeg_path="/usr/bin/ffmpeg",
            url="https://example.com/video.m3u8",
            output_path="video.mp4",
            headers=["Referer: https://example.com"],
            overwrite=True,
        )

        self.assertEqual(
            command,
            [
                "/usr/bin/ffmpeg",
                "-y",
                "-headers",
                "Referer: https://example.com\r\n",
                "-allowed_segment_extensions",
                "ALL",
                "-allowed_extensions",
                "ALL",
                "-i",
                "https://example.com/video.m3u8",
                "-c",
                "copy",
                "-bsf:a",
                "aac_adtstoasc",
                "video.mp4",
            ],
        )

    def test_build_ffmpeg_command_uses_no_overwrite_flag(self):
        command = download_m3u8.build_ffmpeg_command(
            ffmpeg_path="/usr/bin/ffmpeg",
            url="https://example.com/video.m3u8",
            output_path="video.mp4",
            headers=[],
            overwrite=False,
        )

        self.assertIn("-n", command)
        self.assertNotIn("-y", command)

    def test_build_ffmpeg_command_allows_extensionless_hls_segments(self):
        command = download_m3u8.build_ffmpeg_command(
            ffmpeg_path="/usr/bin/ffmpeg",
            url="https://example.com/video.m3u8",
            output_path="video.mp4",
            headers=[],
            overwrite=True,
        )

        option_index = command.index("-allowed_segment_extensions")
        self.assertLess(option_index, command.index("-i"))
        self.assertEqual(command[option_index + 1], "ALL")

    def test_strip_segment_prefix_finds_mpegts_after_fake_image_header(self):
        packet = bytes([0x47]) + b"a" * 187
        segment = b"\x89PNG\r\n\x1a\nfake-header" + (b"\xff" * 16) + (packet * 5)

        self.assertEqual(download_m3u8.strip_segment_prefix(segment), packet * 5)

    def test_strip_segment_prefix_leaves_unknown_data_unchanged(self):
        segment = b"not a transport stream"

        self.assertEqual(download_m3u8.strip_segment_prefix(segment), segment)

    def test_select_variant_playlist_prefers_requested_height(self):
        playlist = "\n".join(
            [
                "#EXTM3U",
                "#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720",
                "720/index.m3u8",
                "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080",
                "1080/index.m3u8",
            ]
        )

        self.assertEqual(
            download_m3u8.select_variant_playlist_url(
                playlist,
                "https://example.com/master.m3u8",
                preferred_height=720,
            ),
            "https://example.com/720/index.m3u8",
        )

    def test_select_variant_playlist_uses_best_bandwidth_when_preference_missing(self):
        playlist = "\n".join(
            [
                "#EXTM3U",
                "#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720",
                "720/index.m3u8",
                "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080",
                "1080/index.m3u8",
            ]
        )

        self.assertEqual(
            download_m3u8.select_variant_playlist_url(
                playlist,
                "https://example.com/master.m3u8",
                preferred_height=480,
            ),
            "https://example.com/1080/index.m3u8",
        )

    def test_resolve_preferred_playlist_url_keeps_media_playlist_url(self):
        with mock.patch("download_m3u8.fetch_url_text", return_value="#EXTM3U\n#EXTINF:8.0,\nseg.ts\n"):
            self.assertEqual(
                download_m3u8.resolve_preferred_playlist_url(
                    url="https://example.com/media.m3u8",
                    headers=[],
                    preferred_height=1080,
                ),
                "https://example.com/media.m3u8",
            )

    def test_rewrite_media_playlist_downloads_and_strips_segments(self):
        playlist = "\n".join(
            [
                "#EXTM3U",
                "#EXT-X-TARGETDURATION:8",
                "#EXTINF:8.0,",
                "segment-one",
                "#EXT-X-ENDLIST",
                "",
            ]
        )
        packet = bytes([0x47]) + b"a" * 187
        fetched = {}

        def fake_fetch_bytes(url, headers, **kwargs):
            fetched[url] = True
            return b"fake-prefix" + packet * 5

        with mock.patch("download_m3u8.fetch_url_bytes", side_effect=fake_fetch_bytes):
            rewritten = download_m3u8.rewrite_media_playlist(
                playlist_text=playlist,
                playlist_url="https://example.com/path/master.m3u8",
                work_dir="/tmp",
                headers=[],
            )

        self.assertIn("segment_00001.ts", rewritten)
        self.assertTrue(fetched["https://example.com/path/segment-one"])

    def test_rewrite_media_playlist_reports_segment_progress_with_totals(self):
        playlist = "\n".join(
            [
                "#EXTM3U",
                "#EXTINF:8.0,",
                "one.ts",
                "#EXTINF:8.0,",
                "two.ts",
            ]
        )

        with mock.patch("download_m3u8.fetch_url_bytes", return_value=b"segment"):
            with mock.patch("download_m3u8.print") as mocked_print:
                download_m3u8.rewrite_media_playlist(
                    playlist_text=playlist,
                    playlist_url="https://example.com/master.m3u8",
                    work_dir="/tmp",
                    headers=[],
                    segment_workers=1,
                )

        messages = [call.args[0] for call in mocked_print.call_args_list]
        self.assertIn("Prepared segment 1/2", messages)
        self.assertIn("Prepared segment 2/2", messages)

    def test_prepare_clean_hls_playlist_reads_and_strips_local_segments(self):
        packet = bytes([0x47]) + b"a" * 187

        with tempfile.TemporaryDirectory() as source_dir:
            playlist_path = download_m3u8.os.path.join(source_dir, "video.m3u8")
            segment_path = download_m3u8.os.path.join(source_dir, "segment.ts")
            with open(playlist_path, "w", encoding="utf-8") as playlist_file:
                playlist_file.write("#EXTM3U\n#EXTINF:8.0,\nsegment.ts\n")
            with open(segment_path, "wb") as segment_file:
                segment_file.write(b"fake-prefix" + packet * 5)

            with tempfile.TemporaryDirectory() as work_dir:
                cleaned_playlist = download_m3u8.prepare_clean_hls_playlist(
                    url=playlist_path,
                    headers=[],
                    work_dir=work_dir,
                    segment_workers=1,
                )
                with open(cleaned_playlist, encoding="utf-8") as playlist_file:
                    rewritten = playlist_file.read()
                with open(
                    download_m3u8.os.path.join(work_dir, "segment_00001.ts"),
                    "rb",
                ) as segment_file:
                    cleaned_segment = segment_file.read()

        self.assertIn("segment_00001.ts", rewritten)
        self.assertEqual(cleaned_segment, packet * 5)

    def test_fetch_url_bytes_retries_timeouts_before_succeeding(self):
        attempts = 0

        class FakeResponse:
            def __enter__(self):
                return self

            def __exit__(self, exc_type, exc, traceback):
                return False

            def read(self):
                return b"segment-data"

        def fake_urlopen(request, timeout):
            nonlocal attempts
            attempts += 1
            if attempts < 3:
                raise TimeoutError("timed out")
            return FakeResponse()

        with mock.patch("download_m3u8.urlopen", side_effect=fake_urlopen):
            data = download_m3u8.fetch_url_bytes(
                "https://example.com/segment.ts",
                [],
                timeout=5,
                retries=3,
            )

        self.assertEqual(data, b"segment-data")
        self.assertEqual(attempts, 3)

    def test_fetch_url_bytes_retries_url_timeout_errors(self):
        attempts = 0

        def fake_urlopen(request, timeout):
            nonlocal attempts
            attempts += 1
            raise URLError(TimeoutError("timed out"))

        with mock.patch("download_m3u8.urlopen", side_effect=fake_urlopen):
            with self.assertRaises(URLError):
                download_m3u8.fetch_url_bytes(
                    "https://example.com/segment.ts",
                    [],
                    timeout=5,
                    retries=2,
                )

        self.assertEqual(attempts, 2)

    def test_parse_args_accepts_segment_download_tuning(self):
        args = download_m3u8.parse_args(
            [
                "https://example.com/video.m3u8",
                "--segment-workers",
                "12",
                "--retries",
                "4",
                "--timeout",
                "15",
                "--quality",
                "1080p",
            ]
        )

        self.assertEqual(args.segment_workers, 12)
        self.assertEqual(args.retries, 4)
        self.assertEqual(args.timeout, 15)
        self.assertEqual(args.quality, "1080p")

    def test_local_playlist_download_returns_ffmpeg_failure_code(self):
        with tempfile.NamedTemporaryFile(suffix=".m3u8") as playlist:
            with mock.patch("download_m3u8.find_ffmpeg", return_value="/usr/bin/ffmpeg"):
                with mock.patch(
                    "download_m3u8.subprocess.run",
                    return_value=mock.Mock(returncode=7),
                ):
                    exit_code = download_m3u8.download([playlist.name, "-o", "local.mp4"])

        self.assertEqual(exit_code, 7)

    def test_local_playlist_download_prepares_segments_before_ffmpeg_combine(self):
        call_order = []

        def fake_prepare_clean_hls_playlist(**kwargs):
            call_order.append("prepare")
            self.assertEqual(kwargs["url"], playlist.name)
            return "/tmp/cleaned-local.m3u8"

        def fake_subprocess_run(command):
            call_order.append("ffmpeg")
            self.assertEqual(command[command.index("-i") + 1], "/tmp/cleaned-local.m3u8")
            return mock.Mock(returncode=0)

        with tempfile.NamedTemporaryFile(suffix=".m3u8") as playlist:
            with mock.patch("download_m3u8.find_ffmpeg", return_value="/usr/bin/ffmpeg"):
                with mock.patch(
                    "download_m3u8.prepare_clean_hls_playlist",
                    side_effect=fake_prepare_clean_hls_playlist,
                ):
                    with mock.patch("download_m3u8.subprocess.run", side_effect=fake_subprocess_run):
                        exit_code = download_m3u8.download([playlist.name, "-o", "local.mp4"])

        self.assertEqual(exit_code, 0)
        self.assertEqual(call_order, ["prepare", "ffmpeg"])

    def test_remote_download_prepares_segments_before_combining_with_ffmpeg(self):
        call_order = []

        def fake_prepare_clean_hls_playlist(**kwargs):
            call_order.append("prepare")
            return "/tmp/cleaned.m3u8"

        def fake_subprocess_run(command):
            call_order.append("ffmpeg")
            self.assertEqual(command[command.index("-i") + 1], "/tmp/cleaned.m3u8")
            return mock.Mock(returncode=0)

        with mock.patch("download_m3u8.find_ffmpeg", return_value="/usr/bin/ffmpeg"):
            with mock.patch(
                "download_m3u8.prepare_clean_hls_playlist",
                side_effect=fake_prepare_clean_hls_playlist,
            ):
                with mock.patch("download_m3u8.subprocess.run", side_effect=fake_subprocess_run):
                    exit_code = download_m3u8.download(
                        ["https://example.com/video.m3u8", "-o", "video.mp4"]
                    )

        self.assertEqual(exit_code, 0)
        self.assertEqual(call_order, ["prepare", "ffmpeg"])

    def test_remote_download_does_not_try_direct_ffmpeg_first(self):
        with mock.patch("download_m3u8.find_ffmpeg", return_value="/usr/bin/ffmpeg"):
            with mock.patch("download_m3u8.resolve_preferred_playlist_url") as resolve:
                with mock.patch(
                    "download_m3u8.prepare_clean_hls_playlist",
                    return_value="/tmp/cleaned.m3u8",
                ):
                    with mock.patch(
                        "download_m3u8.subprocess.run",
                        return_value=mock.Mock(returncode=0),
                    ):
                        exit_code = download_m3u8.download(
                            ["https://example.com/video.m3u8", "-o", "video.mp4"]
                        )

        self.assertEqual(exit_code, 0)
        resolve.assert_not_called()


if __name__ == "__main__":
    unittest.main()
