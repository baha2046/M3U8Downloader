import Foundation

public final class HLSDownloader: Sendable {
    
    public init() {}
    
    /// Main entry point to download HLS stream and prepare a clean local playlist.
    /// Returns the URL of the created local `cleaned.m3u8` file.
    public func download(
        source: String,
        headers: [String],
        workDir: URL,
        quality: String?,
        segmentWorkers: Int,
        retries: Int,
        timeout: Int,
        onLog: @MainActor @escaping (String) -> Void,
        onProgress: @MainActor @escaping (Int, Int) -> Void
    ) async throws -> URL {
        
        let preferredHeight = quality.flatMap { QUALITY_HEIGHTS[$0] }
        
        // 0. Dedicated URLSession tuned for parallel segment downloads.
        //    URLSession.shared caps httpMaximumConnectionsPerHost at 6, which
        //    silently throttles segmentWorkers above 6. Raise it to match.
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = max(segmentWorkers, 6)
        config.timeoutIntervalForRequest = TimeInterval(timeout)
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        
        // 1. Fetch main playlist text
        await onLog("Fetching playlist source: \(source)")
        let isRemote = source.lowercased().hasPrefix("http://") || source.lowercased().hasPrefix("https://")
        
        let playlistText: String
        
        if isRemote {
            guard let url = URL(string: source) else {
                throw NSError(domain: "HLSDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid playlist URL"])
            }
            playlistText = try await fetchTextWithRetries(session: session, url: url, headers: headers, timeout: TimeInterval(timeout), maxRetries: retries, onLog: onLog)
        } else {
            let localUrl = URL(fileURLWithPath: source)
            playlistText = try String(contentsOf: localUrl, encoding: .utf8)
        }
        
        // 2. Handle Master Playlist (Variant selection)
        var mediaPlaylistText = playlistText
        var mediaPlaylistUrl = isRemote ? URL(string: source)! : URL(fileURLWithPath: source)
        
        if playlistText.contains("#EXT-X-STREAM-INF") {
            await onLog("Master playlist detected. Selecting best variant...")
            if let variantUrl = selectVariantUrl(playlistText: playlistText, baseUrl: mediaPlaylistUrl, preferredHeight: preferredHeight) {
                await onLog("Selected variant: \(variantUrl.absoluteString)")
                mediaPlaylistUrl = variantUrl
                if variantUrl.scheme?.lowercased().hasPrefix("http") == true {
                    mediaPlaylistText = try await fetchTextWithRetries(session: session, url: variantUrl, headers: headers, timeout: TimeInterval(timeout), maxRetries: retries, onLog: onLog)
                } else {
                    mediaPlaylistText = try String(contentsOf: variantUrl, encoding: .utf8)
                }
            } else {
                await onLog("Warning: Could not select variant. Defaulting to master playlist.")
            }
        }
        
        // 3. Extract Segments
        let segments = extractSegmentUrls(playlistText: mediaPlaylistText, baseUrl: mediaPlaylistUrl)
        let totalSegments = segments.count
        await onLog("Extracted \(totalSegments) segments to download.")
        
        if totalSegments == 0 {
            throw NSError(domain: "HLSDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "No media segments found in playlist"])
        }
        
        await onLog("preparing cleaned local HLS segments...")
        
        // 4. Download Segments Concurrently.
        //    Networking, prefix-stripping and disk writes all happen inside the
        //    tasks so they run in parallel and off the main actor. The loop body
        //    only does lightweight bookkeeping + progress callbacks.
        try await withThrowingTaskGroup(of: Int.self) { group in
            var activeWorkers = 0
            var segmentIndex = 0
            var completedCount = 0
            
            while segmentIndex < totalSegments || activeWorkers > 0 {
                // Spawn tasks up to segmentWorkers limit
                while activeWorkers < segmentWorkers && segmentIndex < totalSegments {
                    let index = segmentIndex
                    let segmentUrl = segments[index]
                    let fileUrl = workDir.appendingPathComponent(String(format: "segment_%05d.ts", index + 1))
                    
                    group.addTask {
                        let data: Data
                        if segmentUrl.scheme?.lowercased().hasPrefix("http") == true {
                            data = try await self.downloadSegmentWithRetries(
                                session: session,
                                url: segmentUrl,
                                headers: headers,
                                timeout: TimeInterval(timeout),
                                maxRetries: retries
                            )
                        } else {
                            data = try Data(contentsOf: segmentUrl)
                        }
                        // Strip prefix & write to disk in parallel, off the main actor.
                        let cleanData = self.stripSegmentPrefix(data)
                        try cleanData.write(to: fileUrl)
                        return index
                    }
                    segmentIndex += 1
                    activeWorkers += 1
                }
                
                // Retrieve completed tasks
                if try await group.next() != nil {
                    activeWorkers -= 1
                    completedCount += 1
                    
                    // Report progress and log on the Main Actor
                    await onProgress(completedCount, totalSegments)
                    await onLog("Prepared segment \(completedCount)/\(totalSegments)")
                }
            }
        }
        
        // 5. Rewrite and Save Cleaned Local Playlist
        let rewrittenPlaylist = rewritePlaylist(playlistText: mediaPlaylistText, totalSegments: totalSegments)
        let cleanedPlaylistUrl = workDir.appendingPathComponent("cleaned.m3u8")
        try rewrittenPlaylist.write(to: cleanedPlaylistUrl, atomically: true, encoding: .utf8)
        
        await onLog("Cleaned HLS playlist prepared successfully.")
        return cleanedPlaylistUrl
    }
    
    // MARK: - Core Implementation Details
    
    private let QUALITY_HEIGHTS = [
        "720p": 720,
        "1080p": 1080
    ]
    
    private func createRequest(url: URL, headers: [String], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/136.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        
        for header in headers {
            let parts = header.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count == 2 {
                request.setValue(parts[1], forHTTPHeaderField: parts[0])
            }
        }
        return request
    }
    
    private func fetchTextWithRetries(session: URLSession, url: URL, headers: [String], timeout: TimeInterval, maxRetries: Int, onLog: @MainActor @escaping (String) -> Void) async throws -> String {
        let data = try await downloadSegmentWithRetries(session: session, url: url, headers: headers, timeout: timeout, maxRetries: maxRetries)
        guard let text = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "HLSDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to decode playlist response as UTF-8"])
        }
        return text
    }
    
    private func downloadSegmentWithRetries(session: URLSession, url: URL, headers: [String], timeout: TimeInterval, maxRetries: Int) async throws -> Data {
        let attempts = max(1, maxRetries)
        var lastError: Error? = nil
        
        for attempt in 1...attempts {
            do {
                let request = createRequest(url: url, headers: headers, timeout: timeout)
                let (data, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw NSError(domain: "HLSDownloader", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
                }
                return data
            } catch {
                lastError = error
                if attempt < attempts {
                    try? await Task.sleep(nanoseconds: 500_000_000 * UInt64(attempt)) // delay
                }
            }
        }
        throw lastError ?? NSError(domain: "HLSDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed download: \(url.lastPathComponent)"])
    }
    
    private func selectVariantUrl(playlistText: String, baseUrl: URL, preferredHeight: Int?) -> URL? {
        let lines = playlistText.components(separatedBy: .newlines)
        var variants: [(height: Int?, bandwidth: Int, url: URL)] = []
        
        for i in 0..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                var bandwidth = 0
                if let bwRange = line.range(of: #"BANDWIDTH=(\d+)"#, options: .regularExpression),
                   let bwMatch = line[bwRange].split(separator: "=").last,
                   let bwVal = Int(bwMatch) {
                    bandwidth = bwVal
                }
                
                var height: Int? = nil
                if let resRange = line.range(of: #"RESOLUTION=\d+x(\d+)"#, options: .regularExpression),
                   let resMatch = line[resRange].split(separator: "x").last,
                   let hVal = Int(resMatch) {
                    height = hVal
                }
                
                for j in (i+1)..<lines.count {
                    let nextLine = lines[j].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !nextLine.isEmpty && !nextLine.hasPrefix("#") {
                        if let absoluteUrl = URL(string: nextLine, relativeTo: baseUrl)?.absoluteURL {
                            variants.append((height, bandwidth, absoluteUrl))
                        }
                        break
                    }
                }
            }
        }
        
        if variants.isEmpty { return nil }
        
        if let preferredHeight = preferredHeight {
            let preferred = variants.filter { $0.height == preferredHeight }
            if !preferred.isEmpty {
                return preferred.max(by: { $0.bandwidth < $1.bandwidth })?.url
            }
        }
        return variants.max(by: { $0.bandwidth < $1.bandwidth })?.url
    }
    
    private func extractSegmentUrls(playlistText: String, baseUrl: URL) -> [URL] {
        let lines = playlistText.components(separatedBy: .newlines)
        var segmentUrls: [URL] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                if let absoluteUrl = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL {
                    segmentUrls.append(absoluteUrl)
                }
            }
        }
        return segmentUrls
    }
    
    private func stripSegmentPrefix(_ data: Data) -> Data {
        if let offset = mpegtsOffset(in: data) {
            if offset > 0 {
                return data.subdata(in: offset..<data.count)
            }
        }
        return data
    }
    
    private func mpegtsOffset(in data: Data) -> Int? {
        let maxOffset = min(data.count, 4096)
        for offset in 0..<maxOffset {
            var matches = true
            for packetIndex in 0..<5 {
                let checkPos = offset + (188 * packetIndex)
                if checkPos >= data.count || data[checkPos] != 0x47 {
                    matches = false
                    break
                }
            }
            if matches {
                return offset
            }
        }
        return nil
    }
    
    private func rewritePlaylist(playlistText: String, totalSegments: Int) -> String {
        let lines = playlistText.components(separatedBy: .newlines)
        var rewrittenLines: [String] = []
        var segmentIndex = 1
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                let localFilename = String(format: "segment_%05d.ts", segmentIndex)
                rewrittenLines.append(localFilename)
                segmentIndex += 1
            } else {
                rewrittenLines.append(line)
            }
        }
        return rewrittenLines.joined(separator: "\n")
    }
}
