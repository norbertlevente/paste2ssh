import AppKit
import Foundation
import UserNotifications

enum Notifier {
    static func notify(title: String, body: String, enabled: Bool) {
        guard enabled else {
            return
        }
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }

        Task {
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    return
                }

                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                content.sound = .default

                let request = UNNotificationRequest(
                    identifier: "paste2ssh-\(UUID().uuidString)",
                    content: content,
                    trigger: nil
                )
                try await center.add(request)
            } catch {
                return
            }
        }
    }

    static func successSound() {
        NSSound(named: "Glass")?.play()
    }
}
