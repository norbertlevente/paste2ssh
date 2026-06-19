import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the opt-in "Launch at login" setting.
///
/// `register()` is unreliable for ad-hoc-signed builds or apps run from outside
/// `/Applications`; callers should surface the returned error and reconcile their
/// UI against `isEnabled` rather than assume success.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns `nil` on success, or a user-facing error message on failure.
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
