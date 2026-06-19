import AppKit
import Foundation

@MainActor
final class ClipboardWatcher {
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastHash: String?
    private let onImage: @MainActor (Data) -> Void

    init(onImage: @escaping @MainActor (Data) -> Void) {
        self.onImage = onImage
    }

    func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else {
            return
        }
        lastChangeCount = pasteboard.changeCount

        guard ImageSource.clipboardHasImage(), let data = try? ImageSource.clipboardPNGData() else {
            return
        }

        let hash = ImageSource.hash(data: data)
        guard hash != lastHash else {
            return
        }
        lastHash = hash
        onImage(data)
    }
}
