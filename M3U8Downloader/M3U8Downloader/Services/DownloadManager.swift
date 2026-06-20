import Foundation
import Combine
import SwiftUI

@MainActor
@Observable
public class DownloadManager {
    public static let shared = DownloadManager()
    
    public var jobs: [DownloadJob] = []
    public var maxConcurrentDownloads: Int = 1
    
    // Preferences (will be stored in UserDefaults)
    public var ffmpegPath: String = "" {
        didSet {
            UserDefaults.standard.set(ffmpegPath, forKey: "ffmpegPath")
        }
    }
    
    public var defaultDownloadDir: String = "" {
        didSet {
            UserDefaults.standard.set(defaultDownloadDir, forKey: "defaultDownloadDir")
        }
    }
    
    private var activeProcesses: [UUID: Process] = [:]
    private let queueQueue = DispatchQueue(label: "com.ericchan.m3u8downloader.queue", qos: .background)
    
    private init() {
        // Load settings from UserDefaults or auto-detect
        self.ffmpegPath = UserDefaults.standard.string(forKey: "ffmpegPath") ?? ""
        self.defaultDownloadDir = UserDefaults.standard.string(forKey: "defaultDownloadDir") ?? ""
        
        if self.ffmpegPath.isEmpty {
            self.ffmpegPath = autoDetectFfmpeg()
        }
        if self.defaultDownloadDir.isEmpty {
            self.defaultDownloadDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Downloads"
        }
    }
    
    // MARK: - API Methods
    
    public func addJob(
        url: String,
        sourceType: String,
        outputFilename: String?,
        outputPath: String,
        headers: [String],
        quality: String?,
        overwrite: Bool,
        segmentWorkers: Int,
        retries: Int,
        timeout: Int
    ) -> DownloadJob {
        let job = DownloadJob(
            url: url,
            sourceType: sourceType,
            outputFilename: outputFilename,
            outputPath: outputPath,
            headers: headers,
            quality: quality,
            overwrite: overwrite,
            segmentWorkers: segmentWorkers,
            retries: retries,
            timeout: timeout
        )
        
        self.jobs.append(job)
        self.triggerQueueProcessing()
        return job
    }
    
    public func cancelJob(_ job: DownloadJob) {
        // First kill ffmpeg if active
        if let process = self.activeProcesses[job.id] {
            process.terminate()
            self.activeProcesses.removeValue(forKey: job.id)
        }
        
        job.status = "cancelled"
        job.finishedAt = Date()
        job.addLog("Download cancelled by user.")
        self.triggerQueueProcessing()
    }
    
    public func removeJob(_ job: DownloadJob) {
        cancelJob(job)
        self.jobs.removeAll(where: { $0.id == job.id })
    }
    
    public func retryJob(_ job: DownloadJob) {
        job.status = "queued"
        job.exitCode = nil
        job.startedAt = nil
        job.finishedAt = nil
        job.logs = []
        job.progress = DownloadProgress()
        job.addLog("Re-queued for download.")
        self.triggerQueueProcessing()
    }
    
    // MARK: - Auto-Detection
    
    private func autoDetectFfmpeg() -> String {
        let fm = FileManager.default
        let paths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        for path in paths {
            if fm.fileExists(atPath: path) {
                return path
            }
        }
        return "ffmpeg" // reliance on system PATH
    }
    
    // MARK: - Queue Management
    
    private func triggerQueueProcessing() {
        self.processQueue()
    }
    
    private func processQueue() {
        let runningCount = jobs.filter { $0.status == "running" }.count
        if runningCount >= maxConcurrentDownloads {
            return
        }
        
        guard let nextJob = jobs.first(where: { $0.status == "queued" }) else {
            return
        }
        
        runJob(nextJob)
        
        // Recursively trigger to fill concurrent slots
        processQueue()
    }
    
    private func runJob(_ job: DownloadJob) {
        job.status = "running"
        job.startedAt = Date()
        job.addLog("Initializing native downloader...")
        
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("com.chan.m3u8downloader")
            .appendingPathComponent(job.id.uuidString)
        
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            job.status = "failed"
            job.finishedAt = Date()
            job.addLog("Failed to create temporary folder: \(error.localizedDescription)")
            self.triggerQueueProcessing()
            return
        }
        
        Task {
            let downloader = HLSDownloader()
            let cleanedPlaylistUrl: URL
            
            do {
                cleanedPlaylistUrl = try await downloader.download(
                    source: job.url,
                    headers: job.headers,
                    workDir: tempDir,
                    quality: job.quality,
                    segmentWorkers: job.segmentWorkers,
                    retries: job.retries,
                    timeout: job.timeout,
                    onLog: { logMsg in
                        job.addLog(logMsg)
                    },
                    onProgress: { completed, total in
                        job.progress.stage = "segments"
                        job.progress.completedSegments = completed
                        job.progress.totalSegments = total
                        if total > 0 {
                            job.progress.percent = Double(round(1000.0 * Double(completed) / Double(total)) / 10.0)
                        }
                    }
                )
            } catch {
                await MainActor.run {
                    job.status = "failed"
                    job.finishedAt = Date()
                    job.addLog("Download failed: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: tempDir)
                    self.triggerQueueProcessing()
                }
                return
            }
            
            // Native download succeeded! Now run FFmpeg subprocess
            await MainActor.run {
                if job.status == "cancelled" {
                    try? FileManager.default.removeItem(at: tempDir)
                    return
                }
                
                job.addLog("HLS segments downloaded. Packaging video with FFmpeg...")
                
                let ffmpegProcess = Process()
                ffmpegProcess.executableURL = URL(fileURLWithPath: self.ffmpegPath)
                ffmpegProcess.arguments = [
                    job.overwrite ? "-y" : "-n",
                    "-allowed_segment_extensions", "ALL",
                    "-allowed_extensions", "ALL",
                    "-i", "cleaned.m3u8",
                    "-c", "copy",
                    "-bsf:a", "aac_adtstoasc",
                    job.outputPath
                ]
                ffmpegProcess.currentDirectoryURL = tempDir
                
                // Configure environment to include homebrew/bin paths for dependency libraries
                var env = ProcessInfo.processInfo.environment
                let ffmpegDir = (self.ffmpegPath as NSString).deletingLastPathComponent
                let brewDir = "/opt/homebrew/bin"
                let usrLocalDir = "/usr/local/bin"
                var currentPath = env["PATH"] ?? ""
                
                if !ffmpegDir.isEmpty && !currentPath.contains(ffmpegDir) {
                    currentPath = "\(ffmpegDir):\(currentPath)"
                }
                if !currentPath.contains(brewDir) {
                    currentPath = "\(brewDir):\(currentPath)"
                }
                if !currentPath.contains(usrLocalDir) {
                    currentPath = "\(usrLocalDir):\(currentPath)"
                }
                env["PATH"] = currentPath
                ffmpegProcess.environment = env
                
                job.commandText = self.ffmpegPath + " " + ffmpegProcess.arguments!.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
                job.addLog("Executing FFmpeg: \(job.commandText)")
                
                let pipe = Pipe()
                ffmpegProcess.standardOutput = pipe
                ffmpegProcess.standardError = pipe
                
                self.activeProcesses[job.id] = ffmpegProcess
                
                do {
                    try ffmpegProcess.run()
                } catch {
                    job.status = "failed"
                    job.finishedAt = Date()
                    job.exitCode = -1
                    job.addLog("Failed to execute FFmpeg: \(error.localizedDescription). Verify your FFmpeg path in Preferences.")
                    self.activeProcesses.removeValue(forKey: job.id)
                    try? FileManager.default.removeItem(at: tempDir)
                    self.triggerQueueProcessing()
                    return
                }
                
                let fileHandle = pipe.fileHandleForReading
                Task {
                    do {
                        for try await line in fileHandle.bytes.lines {
                            await MainActor.run {
                                job.addLog(line)
                            }
                        }
                    } catch {
                        await MainActor.run {
                            job.addLog("Error reading FFmpeg log: \(error.localizedDescription)")
                        }
                    }
                    
                    ffmpegProcess.waitUntilExit()
                    
                    let code = Int(ffmpegProcess.terminationStatus)
                    
                    await MainActor.run {
                        self.activeProcesses.removeValue(forKey: job.id)
                        job.exitCode = code
                        job.finishedAt = Date()
                        
                        if job.status == "running" {
                            if code == 0 {
                                job.status = "completed"
                                job.progress.finish(status: "completed")
                                job.addLog("Download finished successfully! Saved to: \(job.outputPath)")
                            } else {
                                job.status = "failed"
                                job.addLog("FFmpeg packaging failed with exit code \(code)")
                            }
                        }
                        
                        try? FileManager.default.removeItem(at: tempDir)
                        self.triggerQueueProcessing()
                    }
                }
            }
        }
    }
}
