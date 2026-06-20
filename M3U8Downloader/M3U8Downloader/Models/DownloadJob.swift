import Foundation

@MainActor
@Observable
public class DownloadProgress {
    public var stage: String? = nil // "segments" or "ffmpeg"
    public var percent: Double? = nil
    public var time: String? = nil
    public var timeSeconds: Double? = nil
    public var duration: String? = nil
    public var durationSeconds: Double? = nil
    public var speed: String? = nil
    public var completedSegments: Int? = nil
    public var totalSegments: Int? = nil

    public init() {}
    
    public func updateFromLog(_ line: String) -> Bool {
        var changed = false
        
        // 1. Match Duration (ffmpeg stage): Duration: 00:05:20.12
        if let durationMatch = line.range(of: #"Duration:\s*(\d+:\d{2}:\d{2}(?:\.\d+)?)"#, options: .regularExpression) {
            let nsRange = NSRange(durationMatch, in: line)
            if let regex = try? NSRegularExpression(pattern: #"Duration:\s*(\d+:\d{2}:\d{2}(?:\.\d+)?)"#),
               let match = regex.firstMatch(in: line, range: nsRange),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: line) {
                self.stage = "ffmpeg"
                let durationStr = String(line[r])
                self.duration = durationStr
                self.durationSeconds = timestampToSeconds(durationStr)
                self.percent = progressPercent(timeSeconds, durationSeconds)
                changed = true
            }
        }
        
        // 2. Match ffmpeg progress: time=00:02:15.50 speed=4.5x
        let timePattern = #"time=(\d+:\d{2}:\d{2}(?:\.\d+)?)"#
        let speedPattern = #"speed=\s*(\S+)"#
        
        var parsedTime: String? = nil
        var parsedSpeed: String? = nil
        
        if let timeRange = line.range(of: timePattern, options: .regularExpression) {
            let nsRange = NSRange(timeRange, in: line)
            if let regex = try? NSRegularExpression(pattern: timePattern),
               let match = regex.firstMatch(in: line, range: nsRange),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: line) {
                parsedTime = String(line[r])
            }
        }
        
        if let speedRange = line.range(of: speedPattern, options: .regularExpression) {
            let nsRange = NSRange(speedRange, in: line)
            if let regex = try? NSRegularExpression(pattern: speedPattern),
               let match = regex.firstMatch(in: line, range: nsRange),
               match.numberOfRanges > 1,
               let r = Range(match.range(at: 1), in: line) {
                parsedSpeed = String(line[r])
            }
        }
        
        if parsedTime != nil || parsedSpeed != nil {
            self.stage = "ffmpeg"
            if let t = parsedTime {
                self.time = t
                self.timeSeconds = timestampToSeconds(t)
            }
            if let s = parsedSpeed {
                self.speed = s
            }
            self.percent = progressPercent(timeSeconds, durationSeconds)
            changed = true
        }
        
        // 3. Match Segments Prep Transition
        if line.contains("preparing cleaned local HLS segments") {
            self.stage = "segments"
            self.percent = nil
            changed = true
        }
        
        // 4. Match Segment Progress: Prepared segment 5/10
        let segmentPattern = #"Prepared segment\s+(\d+)(?:/(\d+))?"#
        if let segmentRange = line.range(of: segmentPattern, options: .regularExpression) {
            let nsRange = NSRange(segmentRange, in: line)
            if let regex = try? NSRegularExpression(pattern: segmentPattern),
               let match = regex.firstMatch(in: line, range: nsRange),
               match.numberOfRanges > 1 {
                self.stage = "segments"
                if let r1 = Range(match.range(at: 1), in: line), let completed = Int(line[r1]) {
                    self.completedSegments = completed
                    if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound,
                       let r2 = Range(match.range(at: 2), in: line), let total = Int(line[r2]) {
                        self.totalSegments = total
                        self.percent = progressPercent(Double(completed), Double(total))
                    }
                }
                changed = true
            }
        }
        
        return changed
    }
    
    public func finish(status: String) {
        if status == "completed" {
            self.percent = 100.0
        }
    }
    
    private func timestampToSeconds(_ value: String) -> Double {
        let parts = value.split(separator: ":").map { String($0) }
        guard parts.count == 3 else { return 0.0 }
        let hours = Double(parts[0]) ?? 0.0
        let minutes = Double(parts[1]) ?? 0.0
        let seconds = Double(parts[2]) ?? 0.0
        return (hours * 3600.0) + (minutes * 60.0) + seconds
    }
    
    private func progressPercent(_ current: Double?, _ total: Double?) -> Double? {
        guard let current = current, let total = total, total > 0 else { return nil }
        let raw = (current / total) * 100.0
        return Double(round(10 * max(0.0, min(100.0, raw))) / 10)
    }
}

@MainActor
@Observable
public class DownloadJob: Identifiable {
    public let id: UUID
    public let url: String
    public let sourceType: String // "url" or "local"
    public let outputFilename: String?
    public let outputPath: String
    public let headers: [String]
    public let quality: String?
    public let overwrite: Bool
    public let segmentWorkers: Int
    public let retries: Int
    public let timeout: Int
    
    public var status: String = "queued" // "queued", "running", "completed", "failed", "cancelled"
    public var exitCode: Int? = nil
    public var commandText: String = ""
    public var logs: [String] = []
    public let createdAt: Date = Date()
    public var startedAt: Date? = nil
    public var finishedAt: Date? = nil
    public var progress: DownloadProgress = DownloadProgress()
    
    public init(
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
    ) {
        self.id = UUID()
        self.url = url
        self.sourceType = sourceType
        self.outputFilename = outputFilename
        self.outputPath = outputPath
        self.headers = headers
        self.quality = quality
        self.overwrite = overwrite
        self.segmentWorkers = segmentWorkers
        self.retries = retries
        self.timeout = timeout
    }
    
    public func addLog(_ line: String) {
        self.logs.append(line.trimmingCharacters(in: .newlines))
        _ = self.progress.updateFromLog(line)
    }
}
