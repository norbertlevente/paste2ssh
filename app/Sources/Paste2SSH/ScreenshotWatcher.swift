import Foundation

@MainActor
final class ScreenshotWatcher {
    private var source: (any DispatchSourceFileSystemObject)?
    private var fileDescriptor: CInt = -1
    private var knownPaths = Set<String>()
    private let folder: URL
    private let onFile: @MainActor (URL) -> Void

    init(folder: URL, onFile: @escaping @MainActor (URL) -> Void) {
        self.folder = folder
        self.onFile = onFile
    }

    deinit {
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
    }

    func start() {
        stop()
        seedExistingFiles()
        fileDescriptor = open(folder.path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.scanForNewScreenshots()
            }
        }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
        }
        fileDescriptor = -1
    }

    private func seedExistingFiles() {
        knownPaths.removeAll()
        for url in imageFiles() {
            knownPaths.insert(url.path)
        }
    }

    private func scanForNewScreenshots() {
        for url in imageFiles() where !knownPaths.contains(url.path) {
            knownPaths.insert(url.path)
            Task { @MainActor in
                if await Self.waitUntilStable(url: url) {
                    onFile(url)
                }
            }
        }
    }

    private func imageFiles() -> [URL] {
        let allowed = Set(["png", "jpg", "jpeg", "heic"])
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.filter { url in
            let name = url.lastPathComponent
            guard !name.hasPrefix("."), !name.hasPrefix("Screenshot.") else {
                return false
            }
            guard allowed.contains(url.pathExtension.lowercased()) else {
                return false
            }
            return (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    private nonisolated static func waitUntilStable(url: URL) async -> Bool {
        var previousSize: Int64 = -1
        var stableSamples = 0

        for _ in 0..<12 {
            let size = fileSize(url: url)
            if size > 0 && size == previousSize {
                stableSamples += 1
                if stableSamples >= 2 {
                    return true
                }
            } else {
                stableSamples = 0
            }
            previousSize = size
            try? await Task.sleep(for: .milliseconds(250))
        }

        return fileSize(url: url) > 0
    }

    private nonisolated static func fileSize(url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return -1
        }
        return Int64(values.fileSize ?? -1)
    }
}
