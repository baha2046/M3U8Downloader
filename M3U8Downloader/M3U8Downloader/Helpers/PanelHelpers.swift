import AppKit
import UniformTypeIdentifiers

@MainActor
public struct FolderPickerHelper {
    public static func selectFolder(defaultPath: String?, completion: @MainActor @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Output Directory"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = false
        
        if let defaultPath = defaultPath, !defaultPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: defaultPath)
        }
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                completion(url.path)
            }
        }
    }
}

@MainActor
public struct FilePickerHelper {
    public static func selectM3U8File(completion: @MainActor @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Local .m3u8 File"
        panel.prompt = "Select"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        
        if let m3u8Type = UTType(filenameExtension: "m3u8") {
            panel.allowedContentTypes = [m3u8Type]
        }
        
        panel.begin { response in
            if response == .OK, let url = panel.url {
                completion(url.path)
            }
        }
    }
}
