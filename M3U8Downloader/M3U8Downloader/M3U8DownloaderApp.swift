import SwiftUI

@main
struct M3U8DownloaderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(DownloadManager.shared)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}
