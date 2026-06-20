import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @Environment(DownloadManager.self) private var downloadManager
    
    enum NavigationSelection: Hashable {
        case creator
        case preferences
        case job(UUID)
    }
    
    @State private var selection: NavigationSelection = .creator
    @State private var searchText: String = ""
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                // New Download Button
                Button(action: {
                    selection = .creator
                }) {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)
                        Text("New Download")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.top, 12)
                .padding(.bottom, 8)
                
                Divider()
                
                // Tasks List
                List(selection: $selection) {
                    Section("Downloads") {
                        let filteredJobs = downloadManager.jobs.filter { job in
                            if searchText.isEmpty { return true }
                            return job.url.localizedCaseInsensitiveContains(searchText) ||
                                   job.outputPath.localizedCaseInsensitiveContains(searchText)
                        }
                        
                        if filteredJobs.isEmpty {
                            Text("No downloads")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 4)
                        } else {
                            ForEach(filteredJobs) { job in
                                NavigationLink(value: NavigationSelection.job(job.id)) {
                                    SidebarJobRow(job: job)
                                }
                                .contextMenu {
                                    Button("Show in Finder") {
                                        showInFinder(path: job.outputPath)
                                    }
                                    if job.status == "completed" {
                                        Button("Play Video") {
                                            openVideo(path: job.outputPath)
                                        }
                                    }
                                    if job.status == "failed" || job.status == "cancelled" {
                                        Button("Retry") {
                                            downloadManager.retryJob(job)
                                        }
                                    }
                                    if job.status == "running" {
                                        Button("Cancel") {
                                            downloadManager.cancelJob(job)
                                        }
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        downloadManager.removeJob(job)
                                        if selection == .job(job.id) {
                                            selection = .creator
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $searchText, placement: .sidebar, prompt: "Search downloads...")
                
                Spacer()
                
                Divider()
                
                // Preferences & App Info
                List(selection: $selection) {
                    NavigationLink(value: NavigationSelection.preferences) {
                        Label("Preferences", systemImage: "gearshape.fill")
                    }
                }
                .listStyle(.sidebar)
                .padding(.top, 8)
                .frame(height: 50)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 320)
        } detail: {
            // Detail View
            switch selection {
            case .creator:
                DownloadCreatorView(selection: $selection)
            case .preferences:
                PreferencesView()
            case .job(let jobId):
                if let job = downloadManager.jobs.first(where: { $0.id == jobId }) {
                    JobDetailView(job: job)
                } else {
                    ContentUnavailableView("Job Not Found", systemImage: "questionmark.circle", description: Text("This task may have been deleted."))
                }
            }
        }
    }
}

// MARK: - Helper Actions
func showInFinder(path: String) {
    let fileURL = URL(fileURLWithPath: path)
    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
}

func openVideo(path: String) {
    let fileURL = URL(fileURLWithPath: path)
    NSWorkspace.shared.open(fileURL)
}

// MARK: - Sidebar Job Row
struct SidebarJobRow: View {
    let job: DownloadJob
    
    var body: some View {
        HStack(spacing: 8) {
            // Status Icon / Spinner
            statusIcon
                .font(.title3)
                .frame(width: 24, height: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(job.outputFilename ?? URL(fileURLWithPath: job.outputPath).lastPathComponent)
                    .font(.body)
                    .lineLimit(1)
                
                HStack {
                    if job.status == "running" {
                        if let percent = job.progress.percent {
                            Text("\(Int(percent))%")
                        } else {
                            Text(job.progress.stage == "ffmpeg" ? "FFmpeg..." : "Connecting...")
                        }
                        if let speed = job.progress.speed {
                            Text("• \(speed)")
                        }
                    } else {
                        Text(job.status.capitalized)
                            .foregroundStyle(statusColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch job.status {
        case "queued":
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case "running":
            ProgressView()
                .controlSize(.small)
        case "completed":
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "failed":
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case "cancelled":
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        default:
            Image(systemName: "questionmark")
        }
    }
    
    private var statusColor: Color {
        switch job.status {
        case "completed": return .green
        case "failed": return .red
        case "running": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Download Creator View
struct DownloadCreatorView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @Binding var selection: ContentView.NavigationSelection
    
    @State private var url: String = ""
    @AppStorage("lastSourceType") private var sourceType: String = "url"
    @State private var outputFilename: String = ""
    @AppStorage("lastOutputDir") private var outputDir: String = ""
    
    // Advanced options
    @AppStorage("lastShowAdvanced") private var showAdvanced: Bool = false
    @AppStorage("lastHeaders") private var headers: String = ""
    @AppStorage("lastQuality") private var quality: String = ""
    @AppStorage("lastSegmentWorkers") private var segmentWorkers: Double = 8.0
    @AppStorage("lastRetries") private var retries: Int = 3
    @AppStorage("lastTimeout") private var timeout: Int = 30
    @AppStorage("lastOverwrite") private var overwrite: Bool = true
    
    @State private var isTargeted: Bool = false
    @State private var errorMessage: String? = nil
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("m3u8 to MP4 Downloader")
                        .font(.largeTitle)
                        .bold()
                    Text("Enter a remote playlist URL or choose a local file to package it into an MP4.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 10)
                
                if let errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.octagon.fill")
                        Text(errorMessage)
                        Spacer()
                        Button(action: { self.errorMessage = nil }) {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(Color.red.opacity(0.15))
                    .cornerRadius(8)
                    .foregroundStyle(.red)
                }
                
                // Form Card
                VStack(alignment: .leading, spacing: 16) {
                    // Source Type Picker
                    Picker("Source Type", selection: $sourceType) {
                        Text("Remote URL").tag("url")
                        Text("Local .m3u8 File").tag("local")
                    }
                    .pickerStyle(.segmented)
                    
                    // Input Section
                    if sourceType == "url" {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Playlist URL")
                                .font(.headline)
                            HStack {
                                Image(systemName: "link")
                                    .foregroundStyle(.secondary)
                                TextField("https://example.com/stream.m3u8", text: $url)
                                    .textFieldStyle(.plain)
                                
                                Button("Paste") {
                                    if let pasteboardString = NSPasteboard.general.string(forType: .string) {
                                        url = pasteboardString.trimmingCharacters(in: .whitespacesAndNewlines)
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Local .m3u8 File")
                                .font(.headline)
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.secondary)
                                TextField("Choose or drag a .m3u8 file here...", text: $url)
                                    .textFieldStyle(.plain)
                                    .disabled(true)
                                
                                Button("Browse...") {
                                    FilePickerHelper.selectM3U8File { path in
                                        url = path
                                        // Auto-populate name if empty
                                        if outputFilename.isEmpty {
                                            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                                            outputFilename = name
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(isTargeted ? Color.blue : Color.secondary.opacity(0.2), lineWidth: isTargeted ? 2 : 1))
                            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                                guard let provider = providers.first else { return false }
                                _ = provider.loadObject(ofClass: URL.self) { itemURL, _ in
                                    if let fileURL = itemURL, fileURL.pathExtension.lowercased() == "m3u8" {
                                        DispatchQueue.main.async {
                                            url = fileURL.path
                                            if outputFilename.isEmpty {
                                                outputFilename = fileURL.deletingPathExtension().lastPathComponent
                                            }
                                        }
                                    }
                                }
                                return true
                            }
                        }
                    }
                    
                    // Output Path Section
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Output Settings")
                            .font(.headline)
                        
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                            GridRow {
                                Text("Filename:")
                                    .foregroundStyle(.secondary)
                                TextField("Optional (defaults to playlist name)", text: $outputFilename)
                                    .textFieldStyle(.roundedBorder)
                            }
                            
                            GridRow {
                                Text("Save Folder:")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    TextField("Choose destination...", text: $outputDir)
                                        .textFieldStyle(.roundedBorder)
                                        .disabled(true)
                                    Button("Browse...") {
                                        FolderPickerHelper.selectFolder(defaultPath: outputDir.isEmpty ? downloadManager.defaultDownloadDir : outputDir) { path in
                                            outputDir = path
                                        }
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    
                    Divider()
                    
                    // Advanced Toggle
                    DisclosureGroup("Advanced Settings", isExpanded: $showAdvanced) {
                        VStack(alignment: .leading, spacing: 12) {
                            // Headers
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Custom HTTP Headers")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $headers)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(height: 60)
                                    .padding(4)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                                Text("Format: Name: Value (one per line)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                            
                            // Quality
                            Picker("Preferred Quality", selection: $quality) {
                                Text("Auto / Best").tag("")
                                Text("1080p").tag("1080p")
                                Text("720p").tag("720p")
                            }
                            .pickerStyle(.inline)
                            
                            // Segment workers
                            HStack {
                                Text("Segment Workers:")
                                Spacer()
                                Slider(value: $segmentWorkers, in: 1...32, step: 1)
                                    .frame(width: 200)
                                Text("\(Int(segmentWorkers))")
                                    .frame(width: 30, alignment: .trailing)
                            }
                            
                            // Retries and timeout
                            HStack(spacing: 20) {
                                Picker("Max Retries:", selection: $retries) {
                                    ForEach(1...10, id: \.self) { i in
                                        Text("\(i)").tag(i)
                                    }
                                }
                                
                                Picker("Timeout (s):", selection: $timeout) {
                                    ForEach([5, 10, 15, 20, 30, 45, 60, 90, 120], id: \.self) { s in
                                        Text("\(s)s").tag(s)
                                    }
                                }
                            }
                            
                            Toggle("Overwrite existing file", isOn: $overwrite)
                        }
                        .padding(.vertical, 8)
                    }
                    .font(.body)
                    
                    Spacer(minLength: 10)
                    
                    // Action Button
                    Button(action: submitDownload) {
                        HStack {
                            Spacer()
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.title3)
                            Text("Download Stream")
                                .font(.headline)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding(20)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(12)
                .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
            }
            .padding(24)
        }
        .onAppear {
            if outputDir.isEmpty {
                outputDir = downloadManager.defaultDownloadDir
            }
        }
    }
    
    private func submitDownload() {
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        
        guard !trimmedUrl.isEmpty else {
            errorMessage = sourceType == "url" ? "Please enter a playlist URL" : "Please select a local .m3u8 file"
            return
        }
        
        if sourceType == "url" {
            guard trimmedUrl.lowercased().hasPrefix("http://") || trimmedUrl.lowercased().hasPrefix("https://") else {
                errorMessage = "URL must start with http:// or https://"
                return
            }
        } else {
            guard FileManager.default.fileExists(atPath: trimmedUrl) else {
                errorMessage = "Local file was not found"
                return
            }
        }
        
        // Parse headers
        let parsedHeaders = headers.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        
        // Determine final output filepath
        let finalFilename: String
        if !outputFilename.isEmpty {
            let extensionName = (outputFilename as NSString).pathExtension.lowercased()
            finalFilename = extensionName == "mp4" ? outputFilename : outputFilename + ".mp4"
        } else {
            let baseName = URL(fileURLWithPath: trimmedUrl).deletingPathExtension().lastPathComponent
            finalFilename = baseName.isEmpty ? "download.mp4" : baseName + ".mp4"
        }
        
        let finalOutputPath = (outputDir as NSString).appendingPathComponent(finalFilename)
        
        let job = downloadManager.addJob(
            url: trimmedUrl,
            sourceType: sourceType,
            outputFilename: finalFilename,
            outputPath: finalOutputPath,
            headers: parsedHeaders,
            quality: quality.isEmpty ? nil : quality,
            overwrite: overwrite,
            segmentWorkers: Int(segmentWorkers),
            retries: retries,
            timeout: timeout
        )
        
        // Clear forms
        url = ""
        outputFilename = ""
        headers = ""
        
        // Go to selection
        selection = .job(job.id)
    }
}

// MARK: - Job Detail View
struct JobDetailView: View {
    @Bindable var job: DownloadJob
    @Environment(DownloadManager.self) private var downloadManager
    
    var body: some View {
        VStack(spacing: 0) {
            // Header panel
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.outputFilename ?? URL(fileURLWithPath: job.outputPath).lastPathComponent)
                        .font(.title)
                        .bold()
                    
                    HStack(spacing: 12) {
                        Label(job.sourceType == "url" ? "URL" : "Local File", systemImage: job.sourceType == "url" ? "link" : "doc.fill")
                        Text("•")
                        Text(job.status.capitalized)
                            .bold()
                            .foregroundStyle(statusColor)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                // Controls
                HStack(spacing: 8) {
                    if job.status == "running" {
                        Button(role: .destructive, action: { downloadManager.cancelJob(job) }) {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                    } else {
                        Button(action: { downloadManager.retryJob(job) }) {
                            Label("Retry", systemImage: "arrow.clockwise")
                        }
                        
                        Button(action: { showInFinder(path: job.outputPath) }) {
                            Label("Show in Finder", systemImage: "folder")
                        }
                        
                        if job.status == "completed" {
                            Button(action: { openVideo(path: job.outputPath) }) {
                                Label("Open Video", systemImage: "play.fill")
                            }
                        }
                    }
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Progress Section
            VStack(alignment: .leading, spacing: 14) {
                if job.status == "running" {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(job.progress.stage == "ffmpeg" ? "Merging segments (FFmpeg)..." : "Downloading HLS segments...")
                                .font(.headline)
                            Spacer()
                            if let percent = job.progress.percent {
                                Text("\(Int(percent))%")
                                    .bold()
                            }
                        }
                        
                        if let percent = job.progress.percent {
                            ProgressView(value: percent, total: 100)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                    }
                    
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        if let completed = job.progress.completedSegments, let total = job.progress.totalSegments {
                            GridRow {
                                Text("Segments:")
                                    .foregroundStyle(.secondary)
                                Text("\(completed) / \(total)")
                            }
                        }
                        if let speed = job.progress.speed {
                            GridRow {
                                Text("Download Speed:")
                                    .foregroundStyle(.secondary)
                                Text(speed)
                            }
                        }
                        if let time = job.progress.time, let duration = job.progress.duration {
                            GridRow {
                                Text("Time Elapsed:")
                                    .foregroundStyle(.secondary)
                                Text("\(time) of \(duration)")
                            }
                        }
                    }
                    .font(.body)
                } else if job.status == "completed" {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download Completed")
                                .font(.headline)
                            Text("Output file saved successfully.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.green.opacity(0.08))
                    .cornerRadius(8)
                } else if job.status == "failed" {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download Failed")
                                .font(.headline)
                            if let code = job.exitCode {
                                Text("Process exited with error code \(code). See logs below.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color.red.opacity(0.08))
                    .cornerRadius(8)
                } else if job.status == "cancelled" {
                    HStack(spacing: 12) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Download Cancelled")
                                .font(.headline)
                            Text("Task was stopped manually.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
            }
            .padding(20)
            
            Divider()
            
            // Console Terminal Logs
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Console Output Logs", systemImage: "terminal")
                        .font(.headline)
                    Spacer()
                    Button("Copy Logs") {
                        let text = job.logs.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                
                Divider()
                
                // Terminal View
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(0..<job.logs.count, id: \.self) { index in
                                Text(job.logs[index])
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .id(index)
                            }
                        }
                        .padding(12)
                    }
                    .background(Color.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: job.logs.count) {
                        if !job.logs.isEmpty {
                            withAnimation {
                                proxy.scrollTo(job.logs.count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private var statusColor: Color {
        switch job.status {
        case "completed": return .green
        case "failed": return .red
        case "running": return .blue
        case "cancelled": return .secondary
        default: return .orange
        }
    }
}

// MARK: - Preferences View
struct PreferencesView: View {
    @Environment(DownloadManager.self) private var downloadManager
    @State private var ffmpegPath: String = ""
    @State private var defaultDownloadDir: String = ""
    @State private var maxConcurrent: Int = 1
    
    var body: some View {
        Form {
            Section("Executables Settings") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("FFmpeg Executable Path")
                        .font(.headline)
                    HStack {
                        TextField("/opt/homebrew/bin/ffmpeg", text: $ffmpegPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Verify") {
                            verifyExecutable(path: ffmpegPath)
                        }
                    }
                    Text("Required to package HLS segments into the final MP4 video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 16)
            
            Section("Download Settings") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Default Download Folder")
                        .font(.headline)
                    HStack {
                        TextField("Choose...", text: $defaultDownloadDir)
                            .textFieldStyle(.roundedBorder)
                            .disabled(true)
                        Button("Browse...") {
                            FolderPickerHelper.selectFolder(defaultPath: defaultDownloadDir) { path in
                                defaultDownloadDir = path
                            }
                        }
                    }
                }
                .padding(.bottom, 10)
                
                Picker("Max Concurrent Downloads:", selection: $maxConcurrent) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                    Text("4").tag(4)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            ffmpegPath = downloadManager.ffmpegPath
            defaultDownloadDir = downloadManager.defaultDownloadDir
            maxConcurrent = downloadManager.maxConcurrentDownloads
        }
        .onChange(of: ffmpegPath) { downloadManager.ffmpegPath = ffmpegPath }
        .onChange(of: defaultDownloadDir) { downloadManager.defaultDownloadDir = defaultDownloadDir }
        .onChange(of: maxConcurrent) { downloadManager.maxConcurrentDownloads = maxConcurrent }
    }
    
    private func verifyExecutable(path: String) {
        let fm = FileManager.default
        let title = "Verification"
        let msg: String
        
        if path.isEmpty {
            msg = "Path is empty."
        } else if fm.fileExists(atPath: path) {
            msg = "Valid file found at path!"
        } else {
            msg = "File does not exist at this path. Please check again."
        }
        
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = msg
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
