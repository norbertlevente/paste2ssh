import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater so SwiftUI can drive a
/// "Check for Updates…" item and reflect availability. The actual auto-update
/// behavior (background checks, auto-download, install on relaunch) is configured
/// by the SU* keys in Info.plist; Sparkle's standard user driver shows the
/// "Update ready — Relaunch" prompt on its own.
@MainActor
@Observable
final class Updater {
    var canCheckForUpdates = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        canCheckForUpdates = controller.updater.canCheckForUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.canCheckForUpdates = self.controller.updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
