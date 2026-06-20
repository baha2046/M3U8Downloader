#!/usr/bin/env python3
"""Local Flask UI for the m3u8 downloader CLI."""

from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any

from flask import Flask, Response, jsonify, render_template, request, send_file

import download_m3u8


PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
CLI_SCRIPT = os.path.join(PROJECT_DIR, "download_m3u8.py")
PYTHON_EXECUTABLE = sys.executable
TERMINAL_STATUSES = {"completed", "failed"}
UPLOAD_DIR = os.path.join(tempfile.gettempdir(), "download_m3u8_uploads")
FFMPEG_DURATION_PATTERN = re.compile(r"Duration:\s*(\d+:\d{2}:\d{2}(?:\.\d+)?)")
FFMPEG_PROGRESS_PATTERN = re.compile(
    r"(?:^|\s)time=(?P<time>\d+:\d{2}:\d{2}(?:\.\d+)?).*?(?:^|\s)speed=\s*(?P<speed>\S+)"
)
SEGMENT_PROGRESS_PATTERN = re.compile(r"Prepared segment\s+(\d+)(?:/(\d+))?")


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def isoformat(value: datetime | None) -> str | None:
    return value.isoformat() if value else None


def parse_bool(value: Any, default: bool = True) -> bool:
    if value is None or value == "":
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return bool(value)


def parse_positive_int(value: Any, default: int, field_name: str) -> int:
    if value is None or value == "":
        return default
    try:
        parsed = int(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{field_name} must be a number") from error
    if parsed < 1:
        raise ValueError(f"{field_name} must be at least 1")
    return parsed


def parse_headers(value: Any) -> list[str]:
    if value is None:
        return []
    if isinstance(value, list):
        return [str(header).strip() for header in value if str(header).strip()]
    return [line.strip() for line in str(value).splitlines() if line.strip()]


def request_payload() -> dict[str, Any]:
    if request.is_json:
        payload = request.get_json(silent=True)
        return payload if isinstance(payload, dict) else {}
    return request.form.to_dict()


def safe_upload_basename(filename: str) -> str:
    basename = os.path.basename(filename).strip()
    sanitized = re.sub(r"[^A-Za-z0-9._-]+", "_", basename)
    return sanitized or "playlist.m3u8"


def timestamp_to_seconds(value: str) -> float:
    hours, minutes, seconds = value.split(":")
    return (int(hours) * 3600) + (int(minutes) * 60) + float(seconds)


def progress_percent(current: float | None, total: float | None) -> float | None:
    if current is None or total is None or total <= 0:
        return None
    return round(max(0.0, min(100.0, (current / total) * 100)), 1)


@dataclass
class DownloadProgress:
    stage: str | None = None
    percent: float | None = None
    time: str | None = None
    time_seconds: float | None = None
    duration: str | None = None
    duration_seconds: float | None = None
    speed: str | None = None
    completed_segments: int | None = None
    total_segments: int | None = None

    def update_from_log(self, line: str) -> bool:
        changed = False
        duration_match = FFMPEG_DURATION_PATTERN.search(line)
        if duration_match:
            self.stage = "ffmpeg"
            self.duration = duration_match.group(1)
            self.duration_seconds = timestamp_to_seconds(self.duration)
            self.percent = progress_percent(self.time_seconds, self.duration_seconds)
            changed = True

        ffmpeg_match = FFMPEG_PROGRESS_PATTERN.search(line)
        if ffmpeg_match:
            self.stage = "ffmpeg"
            self.time = ffmpeg_match.group("time")
            self.time_seconds = timestamp_to_seconds(self.time)
            self.speed = ffmpeg_match.group("speed")
            self.percent = progress_percent(self.time_seconds, self.duration_seconds)
            changed = True

        if "preparing cleaned local HLS segments" in line:
            self.stage = "segments"
            self.percent = None
            changed = True

        segment_match = SEGMENT_PROGRESS_PATTERN.search(line)
        if segment_match:
            self.stage = "segments"
            self.completed_segments = int(segment_match.group(1))
            if segment_match.group(2):
                self.total_segments = int(segment_match.group(2))
            total = self.total_segments
            if total:
                self.percent = progress_percent(self.completed_segments, total)
            changed = True

        return changed

    def finish(self, status: str) -> None:
        if status == "completed" and self.stage:
            self.percent = 100.0

    @classmethod
    def from_logs(cls, logs: list[str], status: str | None = None) -> "DownloadProgress":
        progress = cls()
        for line in logs:
            progress.update_from_log(line)
        if status:
            progress.finish(status)
        return progress

    def has_value(self) -> bool:
        return any(
            value is not None
            for value in (
                self.stage,
                self.percent,
                self.time,
                self.duration,
                self.speed,
                self.completed_segments,
                self.total_segments,
            )
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "stage": self.stage,
            "percent": self.percent,
            "time": self.time,
            "time_seconds": self.time_seconds,
            "duration": self.duration,
            "duration_seconds": self.duration_seconds,
            "speed": self.speed,
            "completed_segments": self.completed_segments,
            "total_segments": self.total_segments,
        }


@dataclass
class DownloadJob:
    id: str
    url: str
    source_type: str
    output: str | None
    output_path: str
    headers: list[str]
    quality: str | None
    overwrite: bool
    segment_workers: int
    retries: int
    timeout: int
    status: str = "queued"
    exit_code: int | None = None
    command: list[str] = field(default_factory=list)
    logs: list[str] = field(default_factory=list)
    created_at: datetime = field(default_factory=utc_now)
    started_at: datetime | None = None
    finished_at: datetime | None = None
    version: int = 0
    progress: DownloadProgress = field(default_factory=DownloadProgress)

    def add_log(self, line: str) -> None:
        self.logs.append(line.rstrip())
        self.progress.update_from_log(line)
        self.version += 1

    def progress_for_response(self) -> DownloadProgress:
        if self.progress.has_value():
            return self.progress
        return DownloadProgress.from_logs(self.logs, self.status)

    def to_dict(self) -> dict[str, Any]:
        progress = self.progress_for_response()
        return {
            "id": self.id,
            "url": self.url,
            "source_type": self.source_type,
            "output": self.output,
            "output_path": self.output_path,
            "headers": self.headers,
            "quality": self.quality,
            "overwrite": self.overwrite,
            "segment_workers": self.segment_workers,
            "retries": self.retries,
            "timeout": self.timeout,
            "status": self.status,
            "exit_code": self.exit_code,
            "command": self.command,
            "command_text": shlex.join(self.command) if self.command else "",
            "logs": self.logs,
            "created_at": isoformat(self.created_at),
            "started_at": isoformat(self.started_at),
            "finished_at": isoformat(self.finished_at),
            "download_url": f"/api/downloads/{self.id}/file"
            if self.status == "completed" and os.path.exists(self.output_path)
            else None,
            "progress": progress.to_dict(),
        }


class DownloadService:
    def __init__(
        self,
        *,
        auto_start_worker: bool = True,
        upload_dir: str = UPLOAD_DIR,
    ):
        self.jobs: dict[str, DownloadJob] = {}
        self.queue: list[str] = []
        self.lock = threading.RLock()
        self.condition = threading.Condition(self.lock)
        self.worker_thread: threading.Thread | None = None
        self.upload_dir = upload_dir
        os.makedirs(self.upload_dir, exist_ok=True)
        if auto_start_worker:
            self.start_worker()

    def start_worker(self) -> None:
        with self.lock:
            if self.worker_thread and self.worker_thread.is_alive():
                return
            self.worker_thread = threading.Thread(target=self.run_worker, daemon=True)
            self.worker_thread.start()

    def save_uploaded_playlist(self, playlist_file: Any) -> str:
        filename = safe_upload_basename(getattr(playlist_file, "filename", ""))
        if not filename.lower().endswith(".m3u8"):
            raise ValueError("Uploaded file must be an .m3u8 file")
        upload_path = os.path.join(self.upload_dir, f"{uuid.uuid4().hex}_{filename}")
        playlist_file.save(upload_path)
        if os.path.getsize(upload_path) == 0:
            os.unlink(upload_path)
            raise ValueError("Uploaded m3u8 file is empty")
        return upload_path

    def enqueue(self, payload: dict[str, Any], playlist_file: Any = None) -> DownloadJob:
        url = str(payload.get("url", "")).strip()
        source_type = "url"
        if url:
            download_m3u8.validate_url(url)
        elif playlist_file and getattr(playlist_file, "filename", ""):
            url = self.save_uploaded_playlist(playlist_file)
            download_m3u8.validate_source(url)
            source_type = "upload"
        else:
            raise ValueError("URL or m3u8 file is required")

        quality = str(payload.get("quality", "")).strip() or None
        if quality and quality not in download_m3u8.QUALITY_HEIGHTS:
            raise ValueError("quality must be 720p or 1080p")

        output = str(payload.get("output", "")).strip() or None
        output_path = (
            download_m3u8.normalize_output_path(output)
            if output
            else download_m3u8.default_output_path(url)
        )
        output_path = os.path.abspath(output_path)
        job = DownloadJob(
            id=uuid.uuid4().hex,
            url=url,
            source_type=source_type,
            output=output,
            output_path=output_path,
            headers=parse_headers(payload.get("headers")),
            quality=quality,
            overwrite=parse_bool(payload.get("overwrite"), default=True),
            segment_workers=parse_positive_int(
                payload.get("segment_workers"),
                download_m3u8.DEFAULT_SEGMENT_WORKERS,
                "segment_workers",
            ),
            retries=parse_positive_int(
                payload.get("retries"),
                download_m3u8.DEFAULT_RETRIES,
                "retries",
            ),
            timeout=parse_positive_int(
                payload.get("timeout"),
                download_m3u8.DEFAULT_TIMEOUT,
                "timeout",
            ),
        )
        job.command = self.build_command(job)
        job.add_log("Queued for download")

        with self.condition:
            self.jobs[job.id] = job
            self.queue.append(job.id)
            self.condition.notify_all()
        return job

    def build_command(self, job: DownloadJob) -> list[str]:
        command = [PYTHON_EXECUTABLE, CLI_SCRIPT, job.url, "--output", job.output_path]
        for header in job.headers:
            command.extend(["--header", header])
        if not job.overwrite:
            command.append("--no-overwrite")
        if job.quality:
            command.extend(["--quality", job.quality])
        command.extend(
            [
                "--segment-workers",
                str(job.segment_workers),
                "--retries",
                str(job.retries),
                "--timeout",
                str(job.timeout),
            ]
        )
        return command

    def list_jobs(self) -> list[DownloadJob]:
        with self.lock:
            return sorted(self.jobs.values(), key=lambda job: job.created_at)

    def get_job(self, job_id: str) -> DownloadJob | None:
        with self.lock:
            return self.jobs.get(job_id)

    def run_worker(self) -> None:
        while True:
            self.run_next_job(wait=True)

    def run_next_job(self, *, wait: bool = False) -> DownloadJob | None:
        with self.condition:
            while not self.queue:
                if not wait:
                    return None
                self.condition.wait()
            job = self.jobs[self.queue.pop(0)]
            job.status = "running"
            job.started_at = utc_now()
            job.version += 1
            job.add_log("Starting download")
            self.condition.notify_all()

        exit_code = 1
        try:
            process = subprocess.Popen(
                job.command,
                cwd=PROJECT_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert process.stdout is not None
            for line in process.stdout:
                with self.condition:
                    job.add_log(line)
                    self.condition.notify_all()
            exit_code = process.wait()
        except Exception as error:  # pragma: no cover - protects background worker
            with self.condition:
                job.add_log(f"error: {error}")
                self.condition.notify_all()

        with self.condition:
            job.exit_code = exit_code
            job.finished_at = utc_now()
            job.status = "completed" if exit_code == 0 else "failed"
            job.progress.finish(job.status)
            job.version += 1
            if job.status == "completed":
                job.add_log(f"Saved MP4 to: {job.output_path}")
            else:
                job.add_log(f"Download failed with exit code {exit_code}")
            self.condition.notify_all()
        return job


def create_app(service: DownloadService | None = None) -> Flask:
    app = Flask(__name__)
    app.config["DOWNLOAD_SERVICE"] = service or DownloadService()

    @app.get("/")
    def index():
        return render_template(
            "index.html",
            defaults={
                "segment_workers": download_m3u8.DEFAULT_SEGMENT_WORKERS,
                "retries": download_m3u8.DEFAULT_RETRIES,
                "timeout": download_m3u8.DEFAULT_TIMEOUT,
            },
        )

    @app.get("/api/downloads")
    def list_downloads():
        current_service: DownloadService = app.config["DOWNLOAD_SERVICE"]
        return jsonify([job.to_dict() for job in current_service.list_jobs()])

    @app.post("/api/downloads")
    def enqueue_download():
        current_service: DownloadService = app.config["DOWNLOAD_SERVICE"]
        try:
            job = current_service.enqueue(
                request_payload(),
                playlist_file=request.files.get("playlist_file"),
            )
        except ValueError as error:
            return jsonify({"error": str(error)}), 400
        return jsonify(job.to_dict()), 201

    @app.get("/api/downloads/<job_id>/events")
    def download_events(job_id: str):
        current_service: DownloadService = app.config["DOWNLOAD_SERVICE"]

        def generate():
            last_version = -1
            while True:
                payload = None
                is_terminal = False
                send_heartbeat = False

                with current_service.condition:
                    while True:
                        job = current_service.jobs.get(job_id)
                        if job is None:
                            payload = {"error": "Download job not found"}
                            is_terminal = True
                            break
                        if job.version != last_version:
                            payload = job.to_dict()
                            is_terminal = job.status in TERMINAL_STATUSES
                            break
                        if not current_service.condition.wait(timeout=15):
                            send_heartbeat = True
                            break

                    if job is not None and job.version != last_version:
                        last_version = job.version

                if payload is not None:
                    yield format_sse(payload)
                    if is_terminal:
                        return
                elif send_heartbeat:
                    yield ": keep-alive\n\n"

        return Response(
            generate(),
            mimetype="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    @app.get("/api/downloads/<job_id>/file")
    def download_file(job_id: str):
        current_service: DownloadService = app.config["DOWNLOAD_SERVICE"]
        job = current_service.get_job(job_id)
        if (
            job is None
            or job.status != "completed"
            or not os.path.exists(job.output_path)
        ):
            return jsonify({"error": "Completed file was not found"}), 404
        return send_file(job.output_path, as_attachment=True)

    return app


def format_sse(payload: dict[str, Any]) -> str:
    return f"data: {json.dumps(payload)}\n\n"


def main() -> None:
    app = create_app()
    app.run(host="127.0.0.1", port=5005, debug=False)


if __name__ == "__main__":
    main()
