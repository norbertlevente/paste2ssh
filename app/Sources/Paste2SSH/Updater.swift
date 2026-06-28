import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Auto-update behavior
/// (background checks, auto-download, install on relaunch) is configured by the
/// SU* keys in Info.plist. Via Sparkle's "gentle reminders", a scheduled check
/// that finds an update sets `updateAvailable` so the app can show its own in-app
/// card instead of Sparkle popping its standard window.
@MainActor
@Observable
final class Updater {
    var canCheckForUpdates = false
    /// True when a background check has found an update the user hasn't acted on yet.
    var updateAvailable = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private let driverDelegate = GentleUpdaterDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        let delegate = driverDelegate
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: delegate
        )
        delegate.onShowScheduledUpdate = { [weak self] in self?.updateAvailable = true }
        delegate.onFinishSession = { [weak self] in self?.updateAvailable = false }

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

/// Bridges Sparkle's gentle scheduled-update reminders to the in-app card.
/// Sparkle invokes these on the main thread.
private final class GentleUpdaterDelegate: NSObject, SPUStandardUserDriverDelegate {
    var onShowScheduledUpdate: (@MainActor () -> Void)?
    var onFinishSession: (@MainActor () -> Void)?

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        // We surface scheduled updates via our own card, not Sparkle's window.
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        let callback = onShowScheduledUpdate
        MainActor.assumeIsolated { callback?() }
    }

    func standardUserDriverWillFinishUpdateSession() {
        let callback = onFinishSession
        MainActor.assumeIsolated { callback?() }
    }
}
