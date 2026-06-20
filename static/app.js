const form = document.querySelector("#download-form");
const jobsEl = document.querySelector("#jobs");
const messageEl = document.querySelector("#form-message");
const refreshButton = document.querySelector("#refresh-button");
const eventSources = new Map();
const jobs = new Map();

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function formPayload() {
  const payload = new FormData(form);
  payload.set("overwrite", document.querySelector("#overwrite").checked ? "true" : "false");
  return payload;
}

async function enqueueDownload(event) {
  event.preventDefault();
  messageEl.textContent = "Queueing...";

  const response = await fetch("/api/downloads", {
    method: "POST",
    body: formPayload(),
  });
  const data = await response.json();

  if (!response.ok) {
    messageEl.textContent = data.error || "Could not queue download.";
    return;
  }

  messageEl.textContent = "Download queued.";
  jobs.set(data.id, data);
  renderJobs();
  watchJob(data.id);
}

async function loadJobs() {
  const response = await fetch("/api/downloads");
  const data = await response.json();
  jobs.clear();
  for (const job of data) {
    jobs.set(job.id, job);
    if (!["completed", "failed"].includes(job.status)) {
      watchJob(job.id);
    }
  }
  renderJobs();
}

function watchJob(jobId) {
  if (eventSources.has(jobId)) {
    return;
  }
  const source = new EventSource(`/api/downloads/${jobId}/events`);
  eventSources.set(jobId, source);

  source.onmessage = (event) => {
    const data = JSON.parse(event.data);
    if (data.id) {
      jobs.set(data.id, data);
      renderJobs();
      if (["completed", "failed"].includes(data.status)) {
        source.close();
        eventSources.delete(jobId);
      }
    }
  };

  source.onerror = () => {
    source.close();
    eventSources.delete(jobId);
    setTimeout(loadJobs, 1000);
  };
}

function renderJobs() {
  const list = Array.from(jobs.values()).sort((a, b) => {
    return new Date(b.created_at) - new Date(a.created_at);
  });

  if (list.length === 0) {
    jobsEl.innerHTML = '<div class="empty-state">No downloads queued yet.</div>';
    return;
  }

  jobsEl.innerHTML = list.map(renderJob).join("");
}

function renderJob(job) {
  const logs = job.logs && job.logs.length > 0 ? job.logs.join("\n") : "Waiting for log output...";
  const downloadLink = job.download_url
    ? `<a class="download-link" href="${escapeHtml(job.download_url)}">Download MP4</a>`
    : "";

  return `
    <article class="job-card">
      <header class="job-header">
        <div>
          <p class="job-url">${escapeHtml(job.source_type === "upload" ? "Uploaded m3u8 file" : job.url)}</p>
          <div class="job-meta">${escapeHtml(job.output_path)}</div>
        </div>
        <span class="status ${escapeHtml(job.status)}">${escapeHtml(job.status)}</span>
      </header>
      <div class="job-body">
        <div class="command-line">${escapeHtml(job.command_text)}</div>
        ${renderProgress(job)}
        <div class="log-panel">${escapeHtml(logs)}</div>
        <div class="file-row">
          <span>${escapeHtml(job.status === "completed" ? `Saved to ${job.output_path}` : statusMessage(job))}</span>
          ${downloadLink}
        </div>
      </div>
    </article>
  `;
}

function renderProgress(job) {
  const progress = progressForJob(job);
  const percent = Number.isFinite(progress.percent) ? progress.percent : 0;
  const percentText = Number.isFinite(progress.percent) ? `${progress.percent.toFixed(1)}%` : "--";
  const stage = progress.stage ? progress.stageLabel || progress.stage : job.status;
  const timeText = progress.time
    ? progress.duration
      ? `${progress.time} / ${progress.duration}`
      : progress.time
    : "--";
  const speedText = progress.speed || "--";
  const segmentText = progress.total_segments
    ? `${progress.completed_segments ?? 0} / ${progress.total_segments} segments`
    : "";

  return `
    <section class="progress-panel" aria-label="Download progress">
      <div class="progress-topline">
        <span class="progress-stage">${escapeHtml(stage)}</span>
        <span class="progress-percent">${escapeHtml(percentText)}</span>
      </div>
      <div class="progress-track" role="progressbar" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${escapeHtml(percent)}">
        <div class="progress-fill" style="width: ${escapeHtml(percent)}%"></div>
      </div>
      <dl class="progress-details">
        <div>
          <dt>Time</dt>
          <dd>${escapeHtml(timeText)}</dd>
        </div>
        <div>
          <dt>Speed</dt>
          <dd>${escapeHtml(speedText)}</dd>
        </div>
        <div>
          <dt>Segments</dt>
          <dd>${escapeHtml(segmentText || "--")}</dd>
        </div>
      </dl>
    </section>
  `;
}

function progressForJob(job) {
  const progress = job.progress || {};
  if (hasProgressValue(progress)) {
    return progress;
  }
  return progressFromLogs(job.logs || [], job.status);
}

function hasProgressValue(progress) {
  return [
    progress.stage,
    progress.percent,
    progress.time,
    progress.duration,
    progress.speed,
    progress.completed_segments,
    progress.total_segments,
  ].some((value) => value !== undefined && value !== null);
}

function progressFromLogs(logs, status) {
  const progress = {};
  for (const line of logs) {
    updateProgressFromLog(progress, line);
  }
  if (status === "completed" && hasProgressValue(progress)) {
    progress.percent = 100;
  }
  return progress;
}

function updateProgressFromLog(progress, line) {
  const durationMatch = String(line).match(/Duration:\s*(\d+:\d{2}:\d{2}(?:\.\d+)?)/);
  if (durationMatch) {
    progress.stage = "ffmpeg";
    progress.duration = durationMatch[1];
    progress.duration_seconds = timestampToSeconds(progress.duration);
    progress.percent = progressPercent(progress.time_seconds, progress.duration_seconds);
  }

  const ffmpegMatch = String(line).match(/(?:^|\s)time=(\d+:\d{2}:\d{2}(?:\.\d+)?).*?(?:^|\s)speed=\s*(\S+)/);
  if (ffmpegMatch) {
    progress.stage = "ffmpeg";
    progress.time = ffmpegMatch[1];
    progress.time_seconds = timestampToSeconds(progress.time);
    progress.speed = ffmpegMatch[2];
    progress.percent = progressPercent(progress.time_seconds, progress.duration_seconds);
  }

  if (String(line).includes("preparing cleaned local HLS segments")) {
    progress.stage = "segments";
    progress.percent = undefined;
  }

  const segmentMatch = String(line).match(/Prepared segment\s+(\d+)(?:\/(\d+))?/);
  if (segmentMatch) {
    progress.stage = "segments";
    progress.completed_segments = Number(segmentMatch[1]);
    if (segmentMatch[2]) {
      progress.total_segments = Number(segmentMatch[2]);
    }
    if (progress.total_segments) {
      progress.percent = progressPercent(progress.completed_segments, progress.total_segments);
    }
  }
}

function timestampToSeconds(value) {
  const [hours, minutes, seconds] = String(value).split(":");
  return (Number(hours) * 3600) + (Number(minutes) * 60) + Number(seconds);
}

function progressPercent(current, total) {
  if (!Number.isFinite(current) || !Number.isFinite(total) || total <= 0) {
    return undefined;
  }
  return Math.round(Math.max(0, Math.min(100, (current / total) * 100)) * 10) / 10;
}

function statusMessage(job) {
  if (job.status === "failed") {
    return `Failed with exit code ${job.exit_code ?? "unknown"}`;
  }
  if (job.status === "running") {
    return "Download is running";
  }
  return "Waiting in queue";
}

form.addEventListener("submit", enqueueDownload);
refreshButton.addEventListener("click", loadJobs);
loadJobs();
