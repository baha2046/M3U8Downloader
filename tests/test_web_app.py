import io
import os
import tempfile
import threading
import time
import unittest
from unittest import mock

import web_app


class WebAppTests(unittest.TestCase):
    def setUp(self):
        self.upload_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.upload_dir.cleanup)
        self.service = web_app.DownloadService(
            auto_start_worker=False,
            upload_dir=self.upload_dir.name,
        )
        self.app = web_app.create_app(self.service)
        self.client = self.app.test_client()

    def test_enqueue_requires_url_or_uploaded_file(self):
        response = self.client.post("/api/downloads", json={"url": ""})

        self.assertEqual(response.status_code, 400)
        self.assertIn("URL or m3u8 file is required", response.get_json()["error"])

    def test_enqueue_accepts_uploaded_m3u8_file(self):
        response = self.client.post(
            "/api/downloads",
            data={
                "playlist_file": (io.BytesIO(b"#EXTM3U\n#EXTINF:8,\nhttps://example.com/seg.ts\n"), "local.m3u8"),
                "output": "uploaded-video",
            },
            content_type="multipart/form-data",
        )

        self.assertEqual(response.status_code, 201)
        data = response.get_json()
        self.assertEqual(data["status"], "queued")
        self.assertEqual(data["source_type"], "upload")
        self.assertTrue(data["url"].endswith(".m3u8"))
        self.assertTrue(os.path.exists(data["url"]))
        self.assertIn(data["url"], data["command"])
        self.assertEqual(data["output_path"], os.path.abspath("uploaded-video.mp4"))

    def test_enqueue_returns_job_id_and_defaults(self):
        response = self.client.post(
            "/api/downloads",
            json={"url": "https://example.com/video.m3u8"},
        )

        self.assertEqual(response.status_code, 201)
        data = response.get_json()
        self.assertEqual(data["status"], "queued")
        self.assertTrue(data["id"])
        self.assertEqual(
            data["output_path"],
            os.path.abspath(
                os.path.join(os.path.expanduser("~/Downloads"), "video.mp4")
            ),
        )

    def test_build_command_maps_form_values_to_cli_arguments(self):
        job = self.service.enqueue(
            {
                "url": "https://example.com/video.m3u8",
                "output": "movie",
                "headers": "Referer: https://example.com\nUser-Agent: Test Browser\n\n",
                "quality": "1080p",
                "overwrite": False,
                "segment_workers": 12,
                "retries": 4,
                "timeout": 15,
            }
        )

        command = self.service.build_command(job)

        self.assertEqual(command[0], web_app.PYTHON_EXECUTABLE)
        self.assertEqual(command[1], web_app.CLI_SCRIPT)
        self.assertIn("https://example.com/video.m3u8", command)
        self.assertIn("--no-overwrite", command)
        self.assertIn("--quality", command)
        self.assertIn("1080p", command)
        self.assertIn("--segment-workers", command)
        self.assertIn("12", command)
        self.assertIn("--retries", command)
        self.assertIn("4", command)
        self.assertIn("--timeout", command)
        self.assertIn("15", command)
        self.assertEqual(command.count("--header"), 2)
        self.assertEqual(job.output_path, os.path.abspath("movie.mp4"))

    def test_build_command_uses_user_downloads_default_when_output_is_blank(self):
        job = self.service.enqueue({"url": "https://example.com/movie.m3u8"})

        command = self.service.build_command(job)

        self.assertEqual(
            job.output_path,
            os.path.abspath(
                os.path.join(os.path.expanduser("~/Downloads"), "movie.mp4")
            ),
        )
        self.assertIn("--output", command)
        self.assertIn(job.output_path, command)

    def test_worker_runs_jobs_sequentially_and_marks_completed(self):
        first = self.service.enqueue({"url": "https://example.com/one.m3u8"})
        second = self.service.enqueue({"url": "https://example.com/two.m3u8"})
        calls = []

        def fake_popen(command, **kwargs):
            calls.append(command)
            return FakeProcess(["Saved MP4 to: /tmp/video.mp4\n"], returncode=0)

        with mock.patch("web_app.subprocess.Popen", side_effect=fake_popen):
            self.service.run_next_job()
            self.service.run_next_job()

        self.assertEqual(first.status, "completed")
        self.assertEqual(second.status, "completed")
        self.assertLess(first.finished_at, second.finished_at)
        self.assertEqual(len(calls), 2)

    def test_failed_subprocess_marks_job_failed_and_stores_logs(self):
        job = self.service.enqueue({"url": "https://example.com/video.m3u8"})

        with mock.patch(
            "web_app.subprocess.Popen",
            return_value=FakeProcess(["ffmpeg error\n"], returncode=1),
        ):
            self.service.run_next_job()

        self.assertEqual(job.status, "failed")
        self.assertEqual(job.exit_code, 1)
        self.assertIn("ffmpeg error", "\n".join(job.logs))

    def test_parser_extracts_ffmpeg_progress_with_percent_time_and_speed(self):
        progress = web_app.DownloadProgress()

        progress.update_from_log("  Duration: 00:01:20.00, start: 0.000000, bitrate: 1100 kb/s")
        progress.update_from_log(
            "frame=  240 fps= 24 q=-1.0 size=    1024kB time=00:00:20.00 bitrate= 419.4kbits/s speed=1.25x"
        )

        self.assertEqual(progress.stage, "ffmpeg")
        self.assertEqual(progress.percent, 25.0)
        self.assertEqual(progress.time, "00:00:20.00")
        self.assertEqual(progress.duration, "00:01:20.00")
        self.assertEqual(progress.speed, "1.25x")

    def test_parser_extracts_segment_progress_when_segments_are_prepared(self):
        progress = web_app.DownloadProgress()

        progress.update_from_log("preparing cleaned local HLS segments...")
        progress.update_from_log("Prepared segment 3/12")

        self.assertEqual(progress.stage, "segments")
        self.assertEqual(progress.percent, 25.0)
        self.assertEqual(progress.completed_segments, 3)
        self.assertEqual(progress.total_segments, 12)

    def test_job_dict_recovers_segment_progress_from_existing_logs(self):
        job = self.service.enqueue({"url": "https://example.com/video.m3u8"})
        job.logs.extend(
            [
                "Queued for download",
                "preparing cleaned local HLS segments...",
                "Prepared segment 156/1964",
            ]
        )

        data = job.to_dict()

        self.assertEqual(data["progress"]["stage"], "segments")
        self.assertEqual(data["progress"]["completed_segments"], 156)
        self.assertEqual(data["progress"]["total_segments"], 1964)
        self.assertEqual(data["progress"]["percent"], 7.9)

    def test_worker_updates_structured_progress_without_dropping_logs(self):
        job = self.service.enqueue({"url": "https://example.com/video.m3u8"})

        with mock.patch(
            "web_app.subprocess.Popen",
            return_value=FakeProcess(
                [
                    "  Duration: 00:00:40.00, start: 0.000000, bitrate: 960 kb/s\n",
                    "frame=  120 fps= 30 q=-1.0 size=     512kB time=00:00:10.00 bitrate= 419.4kbits/s speed=2.0x\n",
                ],
                returncode=1,
            ),
        ):
            self.service.run_next_job()

        data = job.to_dict()
        self.assertIn("Duration: 00:00:40.00", "\n".join(data["logs"]))
        self.assertEqual(data["progress"]["stage"], "ffmpeg")
        self.assertEqual(data["progress"]["percent"], 25.0)
        self.assertEqual(data["progress"]["time"], "00:00:10.00")
        self.assertEqual(data["progress"]["speed"], "2.0x")

    def test_completed_file_can_be_downloaded(self):
        with tempfile.NamedTemporaryFile(delete=False, suffix=".mp4") as output_file:
            output_file.write(b"video")
            output_path = output_file.name
        self.addCleanup(os.unlink, output_path)

        job = self.service.enqueue(
            {
                "url": "https://example.com/video.m3u8",
                "output": output_path,
            }
        )
        job.status = "completed"
        job.output_path = output_path

        response = self.client.get(f"/api/downloads/{job.id}/file")

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.data, b"video")
        response.close()

    def test_incomplete_file_download_returns_404(self):
        job = self.service.enqueue({"url": "https://example.com/video.m3u8"})

        response = self.client.get(f"/api/downloads/{job.id}/file")

        self.assertEqual(response.status_code, 404)

    def test_events_stream_includes_status_and_logs(self):
        job = self.service.enqueue({"url": "https://example.com/video.m3u8"})
        job.add_log("Queued for download")

        response = self.client.get(f"/api/downloads/{job.id}/events", buffered=False)
        self.addCleanup(response.close)

        self.assertEqual(response.status_code, 200)
        body = next(response.iter_encoded()).decode("utf-8")
        self.assertIn('"status": "queued"', body)
        self.assertIn("Queued for download", body)

    def test_events_stream_waits_for_updates_from_long_running_job(self):
        job = self.service.enqueue({"url": "https://example.com/video.m3u8"})
        with self.service.condition:
            job.status = "running"
            job.version += 1
            self.service.condition.notify_all()

        response = self.client.get(f"/api/downloads/{job.id}/events", buffered=False)
        self.addCleanup(response.close)
        stream = response.iter_encoded()

        first_event = next(stream).decode("utf-8")
        self.assertIn('"status": "running"', first_event)

        def add_late_log():
            time.sleep(1.2)
            with self.service.condition:
                job.add_log("still downloading")
                self.service.condition.notify_all()

        update_thread = threading.Thread(target=add_late_log)
        update_thread.start()
        self.addCleanup(update_thread.join)

        second_event = next(stream).decode("utf-8")

        self.assertIn("still downloading", second_event)


class FakeProcess:
    def __init__(self, lines, returncode):
        self.stdout = io.StringIO("".join(lines))
        self.returncode = returncode

    def wait(self):
        return self.returncode


if __name__ == "__main__":
    unittest.main()
